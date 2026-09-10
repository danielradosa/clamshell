import AppKit
import Metal
import QuartzCore

/// The view that owns the Metal layer and paces rendering off the display.
final class MetalView: NSView {

    /// Called once per display refresh, just before drawing.
    var onFrame: ((CAMetalLayer) -> Void)?

    private var displayLink: CADisplayLink?

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(device: MTLDevice) {
        super.init(frame: .zero)
        wantsLayer = true
        let metal = CAMetalLayer()
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = true
        // Draw edge to edge; the window is already exactly one screen.
        metal.contentsGravity = .resize
        layer = metal
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLoop() } else { startLoop() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    private func startLoop() {
        guard displayLink == nil else { return }
        // macOS 14 exposes CADisplayLink on NSView, which tracks the screen the
        // view is actually on and follows ProMotion refresh changes for free.
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

/// A borderless, click-through window that sits above everything on one screen.
final class OverlayWindow: NSWindow {

    init(screen: NSScreen, device: MTLDevice) {
        // The screen: variant is a convenience initializer, so go through the
        // designated one and place the window explicitly afterwards.
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)

        // Above the menu bar, the Dock and full-screen apps. The shielding level
        // is what the screen saver uses, so nothing ordinary outranks it.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true          // never intercept a click
        isReleasedWhenClosed = false
        displaysWhenScreenProfileChanges = true

        // Belt and braces alongside excluding this app in the SCContentFilter:
        // even if the filter were wrong, this keeps the window out of any capture.
        sharingType = .none

        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = MetalView(device: device)
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    var metalView: MetalView { contentView as! MetalView }

    /// Borderless windows refuse key status by default, which is what we want:
    /// the overlay must never steal focus from whatever the user is doing.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        orderFrontRegardless()
    }
}
