import Foundation
import ScreenCaptureKit
import CoreVideo
import Metal
import AppKit

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
    var onFrame: ((MTLTexture) -> Void)?

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
        // attachment tells us which ones carry new pixels.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusValue = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusValue),
           status != .complete {
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer,
              let texture = makeTexture(from: pixelBuffer) else { return }
        onFrame?(texture)
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
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
