import Foundation
import ScreenCaptureKit
import CoreVideo
import Metal
import AppKit

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

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CapturedFrame) -> Void)?

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

    func start(on displayID: CGDirectDisplayID) async throws {
        stop()

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let ourBundleID = Bundle.main.bundleIdentifier
        let ourApps = content.applications.filter { $0.bundleIdentifier == ourBundleID }
        let filter = SCContentFilter(
            display: display, excludingApplications: ourApps, exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.width = display.width * Self.backingScale(for: displayID)
        config.height = display.height * Self.backingScale(for: displayID)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = Self.colorSpaceName(for: displayID)
        config.showsCursor = true
        config.capturesAudio = false
        config.queueDepth = 3
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

    static func colorSpaceName(for displayID: CGDirectDisplayID) -> CFString {
        guard let name = screen(for: displayID)?.colorSpace?.cgColorSpace?.name else {
            return CGColorSpace.sRGB
        }
        return name
    }

    static func colorSpace(for displayID: CGDirectDisplayID) -> CGColorSpace? {
        CGColorSpace(name: colorSpaceName(for: displayID))
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> Int {
        Int(screen(for: displayID)?.backingScaleFactor ?? 2)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

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

        CVMetalTextureCacheFlush(cache, 0)

        return CapturedFrame(texture: texture, cvTexture: cvTexture, pixelBuffer: pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No capturable display was found." }
    }
}
