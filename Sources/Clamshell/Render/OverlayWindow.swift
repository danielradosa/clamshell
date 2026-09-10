import AppKit
import Metal
import QuartzCore

final class MetalView: NSView {
    var onFrame: ((CAMetalLayer) -> Void)?

    private var displayLink: CADisplayLink?

    var isRenderingEnabled = false {
        didSet {
            guard isRenderingEnabled != oldValue else { return }
            isRenderingEnabled ? startLoop() : stopLoop()
        }
    }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(device: MTLDevice, colorSpace: CGColorSpace?) {
        super.init(frame: .zero)
        wantsLayer = true
        let metal = CAMetalLayer()
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = true
        metal.contentsGravity = .resize
        metal.colorspace = colorSpace
        metal.presentsWithTransaction = false
        layer = metal
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func drawNow() {
        updateDrawableSize()
        onFrame?(metalLayer)
    }

    private func startLoop() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateDrawableSize()
    }

    private func stopLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step() {
        onFrame?(metalLayer)
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen, device: MTLDevice) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)

        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        displaysWhenScreenProfileChanges = true

        sharingType = .none

        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let displayID = (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
        let view = MetalView(device: device, colorSpace: ScreenCapture.colorSpace(for: displayID))
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    var metalView: MetalView { contentView as! MetalView }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        fadeOut?.cancel()
        fadeOut = nil
        guard !isVisible || alphaValue < 1 else { return }
        alphaValue = 1
        metalView.isRenderingEnabled = true
        metalView.drawNow()
        orderFrontRegardless()
    }

    func hide() {
        guard isVisible, fadeOut == nil else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.metalView.isRenderingEnabled = false
            self.alphaValue = 1
            self.fadeOut = nil
        }
        fadeOut = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
    }

    private var fadeOut: DispatchWorkItem?
}
