import AppKit
import Metal
import QuartzCore

/// The view that owns the Metal layer and paces rendering off the display.
final class MetalView: NSView {

    /// Called once per display refresh while rendering is enabled.
    var onFrame: ((CAMetalLayer) -> Void)?

    private var displayLink: CADisplayLink?

    /// Whether the display link should be running.
    ///
    /// The window is created once and kept for the life of the app, so the view
    /// always has a window and the link would otherwise run continuously. Gating
    /// it here means a hidden overlay costs nothing.
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
        // Match the display's colour space to the capture's. Leaving this unset
        // lets the window server colour-manage the overlay differently from the
        // desktop underneath, so the two do not match and the handover at the
        // start and end of the effect shows up as a visible pop.
        metal.colorspace = colorSpace
        // Present in step with the window server rather than whenever the GPU
        // finishes, so showing and hiding the window lines up with a real frame.
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

    /// Renders one frame immediately, outside the display link.
    ///
    /// Used to get pixels into the layer *before* the window is shown. Ordering
    /// an overlay on screen whose layer has never presented anything gives a
    /// frame or two of black.
    func drawNow() {
        updateDrawableSize()
        onFrame?(metalLayer)
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
///
/// Created once and kept for the life of the app. An earlier version built and
/// destroyed it on every engagement, which made the effect flicker: the fold
/// threshold sits where the sensor is noisiest, so the window was repeatedly
/// torn down and rebuilt as the reading crossed back and forth.
final class OverlayWindow: NSWindow {

    init(screen: NSScreen, device: MTLDevice) {
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

        // Deliberately not screen.colorSpace: see ScreenCapture.colorSpaceName.
        // The layer must use the exact space the capture was requested in.
        let displayID = (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
        let view = MetalView(device: device, colorSpace: ScreenCapture.colorSpace(for: displayID))
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    var metalView: MetalView { contentView as! MetalView }

    /// Borderless windows refuse key status by default, which is what we want:
    /// the overlay must never steal focus from whatever the user is doing.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Draws a frame into the layer, then shows the window. Order matters — the
    /// other way round shows black until the first frame lands.
    func show() {
        fadeOut?.cancel()
        fadeOut = nil
        guard !isVisible || alphaValue < 1 else { return }
        alphaValue = 1
        metalView.isRenderingEnabled = true
        metalView.drawNow()
        orderFrontRegardless()
    }

    /// Fades out rather than ordering out on the spot.
    ///
    /// By the time this runs the fold is back to nothing, so the overlay is
    /// showing a copy of the desktop that sits directly on top of the real one.
    /// Removing a full-screen window at the shielding level makes the window
    /// server recomposite, and that can drop a frame. Cross-fading two images
    /// that are already identical hides it completely.
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
