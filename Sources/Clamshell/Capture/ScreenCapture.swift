import Foundation
import ScreenCaptureKit
import CoreVideo
import Metal
import AppKit

/// One desktop frame, with everything the GPU texture depends on kept alive.
///
/// `CVMetalTextureGetTexture` hands back a texture that is only valid while its
/// `CVMetalTexture` wrapper lives, and the underlying pixel buffer belongs to a
/// pool that will re-vend and overwrite it once the last reference goes. Holding
/// a frame past the delegate callback therefore means holding all three, not
/// just the `MTLTexture`.
final class CapturedFrame {
    let texture: MTLTexture
    private let cvTexture: CVMetalTexture
    private let pixelBuffer: CVPixelBuffer

    init(texture: MTLTexture, cvTexture: CVMetalTexture, pixelBuffer: CVPixelBuffer) {
        self.texture = texture
        self.cvTexture = cvTexture
        self.pixelBuffer = pixelBuffer
    }
}

/// Streams the live desktop into Metal textures.
///
/// The stream deliberately excludes this application from the capture. Without
/// that, the overlay window would be captured, rendered into the overlay, and
/// captured again — a feedback tunnel. Excluding by *application* rather than by
/// window is what makes this robust: the settings window and any future window
/// are covered automatically, and there is no window-ID bookkeeping to get wrong
/// when a window is recreated.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Called on the capture queue each time a new desktop frame arrives.
    var onFrame: ((CapturedFrame) -> Void)?

    /// Called on the main queue if the stream dies, usually because the display
    /// was reconfigured or permission was revoked.
    var onFailure: ((Error) -> Void)?

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.danielradosa.clamshell.capture", qos: .userInteractive)
    private var isRunning = false

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Whether the user has already granted Screen Recording permission.
    /// Returns false without prompting.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system Screen Recording prompt. Returns immediately; macOS
    /// only shows the prompt once per app, and afterwards the user must grant it
    /// in System Settings.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Starts capturing the display the given window sits on.
    func start(on displayID: CGDirectDisplayID) async throws {
        stop()

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Exclude our whole app so the overlay never feeds back into the capture.
        let ourBundleID = Bundle.main.bundleIdentifier
        let ourApps = content.applications.filter { $0.bundleIdentifier == ourBundleID }
        let filter = SCContentFilter(
            display: display, excludingApplications: ourApps, exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.width = display.width * Self.backingScale(for: displayID)
        config.height = display.height * Self.backingScale(for: displayID)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.capturesAudio = false
        config.queueDepth = 3
        // Cap at 120fps; the renderer paces itself off the display link anyway.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
    }

    func stop() {
        guard let stream, isRunning else { return }
        isRunning = false
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> Int {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        return Int(screen?.backingScaleFactor ?? 2)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // ScreenCaptureKit sends frames even when nothing changed; the status
        // attachment says which ones carry pixels. Both `complete` and `started`
        // do — `started` is the first frame after the stream comes up, and
        // dropping it means a completely static desktop may never render at all.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusValue = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusValue),
           status != .complete, status != .started {
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer,
              let frame = makeFrame(from: pixelBuffer) else { return }
        onFrame?(frame)
    }

    private func makeFrame(from pixelBuffer: CVPixelBuffer) -> CapturedFrame? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }

        // Drops cache entries nothing still references. Frames we are holding
        // keep their own references, so this cannot pull one out from under us.
        CVMetalTextureCacheFlush(cache, 0)

        return CapturedFrame(texture: texture, cvTexture: cvTexture, pixelBuffer: pixelBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No capturable display was found." }
    }
}
