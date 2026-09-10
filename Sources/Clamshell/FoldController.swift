import AppKit
import Metal
import Combine

/// Coordinates the sensor, the capture stream, the renderer and the overlay.
///
/// The controller moves between three states so that an app which is idle most
/// of the day costs almost nothing:
///
///   - `idle`    the lid is open well past the engage angle. Poll the sensor a
///               few times a second and nothing else.
///   - `armed`   the lid has come down near the engage angle. Start the capture
///               stream now, because starting one takes long enough that doing
///               it at the moment of engagement would drop the first frames.
///   - `active`  the fold is visible. Overlay on screen, rendering every frame.
///
/// Arming and disarming use different thresholds so a lid held right at the
/// boundary does not flap the capture stream on and off.
@MainActor
final class FoldController {

    private enum State { case idle, armed, active }

    private let settings = Settings.shared
    private let angleSource = AngleSource()
    private let device: MTLDevice
    private let renderer: FoldRenderer
    private let capture: ScreenCapture

    private var overlay: OverlayWindow?
    private var latestFrame: CapturedFrame?
    private var watchTimer: Timer?
    private var state: State = .idle
    private var cancellables = Set<AnyCancellable>()
    private var wasEngaged = false
    private let escapeHotKey = EscapeHotKey()

    /// How far above the engage angle the capture stream spins up.
    ///
    /// Kept deliberately tight. A generous margin would leave the capture stream
    /// running all day for anyone who works with the lid at a shallow angle,
    /// which is the common case. Motion arming below covers the lead time
    /// instead.
    private let armMargin: Double = 15

    /// Closing speed, in degrees per second, that arms the stream regardless of
    /// angle. Hands close a lid an order of magnitude faster than this, so it
    /// fires as soon as the lid starts moving and buys the stream time to start.
    private let armVelocity: Double = 15

    /// Extra margin before disarming, to stop the stream flapping.
    private let disarmHysteresis: Double = 12

    /// Set when the user pauses from the menu bar or with Escape.
    var isPaused = false { didSet { if isPaused { teardown() } else { angleSource.reset() } } }

    var hasSensor: Bool { angleSource.hasSensor }
    var currentRawAngle: Double { angleSource.rawAngle }

    /// Drives the preview in Settings without needing a second sensor reader.
    @Published private(set) var previewFold: Double = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ControllerError.noMetalDevice }
        self.device = device
        self.renderer = try FoldRenderer(device: device)
        self.capture = ScreenCapture(device: device)

        capture.onFrame = { [weak self] frame in
            // Delivered on the capture queue; hop to main where rendering lives.
            Task { @MainActor in self?.latestFrame = frame }
        }
        capture.onFailure = { [weak self] _ in
            Task { @MainActor in self?.teardown() }
        }

        // A Mac with no lid sensor must sit still by default. Falling back to
        // the looping demo here would mean an app that throws a fullscreen
        // overlay across the screen every few seconds, forever. The demo is
        // reachable on request instead, from the menu or from Settings.
        if !angleSource.hasSensor {
            angleSource.mode = .manual(AngleSource.restingAngle)
        }

        settings.$enabled
            .sink { [weak self] enabled in if !enabled { self?.teardown() } }
            .store(in: &cancellables)

        startWatching()
    }

    /// Switches the angle source, used by the Settings preview.
    func setMode(_ mode: AngleSource.Mode) {
        angleSource.mode = mode
        angleSource.reset()
    }

    // MARK: - The watch loop

    private func startWatching() {
        scheduleWatch(interval: 1.0 / 10.0)
    }

    private func scheduleWatch(interval: TimeInterval) {
        watchTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchTick() }
        }
        // Common mode so menu tracking and window drags do not stall the loop.
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func watchTick() {
        angleSource.tick()
        endDemoIfFinished()
        guard settings.enabled, !isPaused else {
            if state != .idle { teardown() }
            return
        }

        let angle = angleSource.angle
        let engage = settings.engageAngle
        let fold = FoldCurve.progress(angle: angle, engageAngle: engage)
        previewFold = fold

        let closingFast = angleSource.closingVelocity > armVelocity

        switch state {
        case .idle:
            if angle < engage + armMargin || closingFast { transition(to: .armed) }
        case .armed:
            if angle > engage + armMargin + disarmHysteresis && !closingFast {
                transition(to: .idle)
            } else if fold > 0.001, canPresentOverlay {
                transition(to: .active)
            }
        case .active:
            if fold <= 0.001 { transition(to: .armed) }
        }

        // Rendering is driven by the overlay's display link while active; this
        // loop only keeps the angle spring warm and watches for state changes.
        trackClearSound(fold: fold)
    }

    private func transition(to next: State) {
        guard next != state else { return }
        let previous = state
        state = next

        switch next {
        case .idle:
            tearDownOverlay()
            capture.stop()
            latestFrame = nil
            scheduleWatch(interval: 1.0 / 10.0)

        case .armed:
            if previous == .idle { startCapture() }
            if previous == .active { tearDownOverlay() }
            scheduleWatch(interval: 1.0 / 120.0)

        case .active:
            presentOverlay()
            scheduleWatch(interval: 1.0 / 120.0)
        }
    }

    /// The overlay is opaque black until its Metal layer has presented a
    /// drawable, so putting it on screen before the first captured frame lands
    /// would black out the display for a frame or two. Wait for pixels.
    private var canPresentOverlay: Bool {
        latestFrame != nil
    }

    /// Set by the app delegate once the permission check has actually answered.
    /// Nothing tries to capture before then, so a launch with no permission is
    /// quiet rather than a stream of failures.
    var isCaptureAllowed = false

    private func startCapture() {
        guard isCaptureAllowed else { return }
        let displayID = displayIDForOverlay()
        Task { try? await capture.start(on: displayID) }
    }

    private func displayIDForOverlay() -> CGDirectDisplayID {
        // The built-in display is the one with a lid, so prefer it. On a desktop
        // Mac in demo mode, fall back to the main screen.
        let screen = NSScreen.screens.first { $0.localizedName.contains("Built-in") } ?? NSScreen.main
        let number = screen?.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        return number?.uint32Value ?? CGMainDisplayID()
    }

    // MARK: - Overlay

    /// Plays one close-and-open sweep, then settles back. Used from the menu so
    /// the effect can be seen on demand, including on Macs with no sensor.
    func playDemo() {
        angleSource.mode = .demo
        angleSource.reset(to: AngleSource.restingAngle)
        demoDeadline = Date().addingTimeInterval(3.6)
    }

    private var demoDeadline: Date?

    private func endDemoIfFinished() {
        guard let deadline = demoDeadline, Date() >= deadline else { return }
        demoDeadline = nil
        angleSource.mode = angleSource.hasSensor ? .sensor : .manual(AngleSource.restingAngle)
        angleSource.reset()
    }

    private func presentOverlay() {
        guard overlay == nil else { return }
        let screen = NSScreen.screens.first { $0.localizedName.contains("Built-in") } ?? NSScreen.main
        guard let screen else { return }

        let window = OverlayWindow(screen: screen, device: device)
        window.metalView.onFrame = { [weak self] layer in
            Task { @MainActor in self?.drawFrame(into: layer) }
        }
        window.present()
        overlay = window

        // Escape pauses while the fold is on screen, and only while it is.
        escapeHotKey.arm { [weak self] in
            guard let self, !self.isPaused else { return }
            self.isPaused = true
        }
    }

    private func tearDownOverlay() {
        escapeHotKey.disarm()
        overlay?.metalView.onFrame = nil
        overlay?.orderOut(nil)
        overlay = nil
    }

    private func drawFrame(into layer: CAMetalLayer) {
        guard state == .active, let frame = latestFrame else { return }
        // The angle spring is advanced by the watch timer, which runs at 120 Hz
        // while active. Ticking it again here would resample it with a fraction
        // of a frame's dt and skew the closing-velocity estimate.
        let fold = FoldCurve.progress(angle: angleSource.angle, engageAngle: settings.engageAngle)
        guard let drawable = layer.nextDrawable() else { return }
        renderer.render(source: frame.texture, fold: fold, style: settings.style, drawable: drawable)
    }

    // MARK: - Sound

    private func trackClearSound(fold: Double) {
        let engaged = fold > 0.001
        defer { wasEngaged = engaged }
        guard wasEngaged, !engaged, settings.soundEnabled else { return }
        Chime.playClear()
    }

    private func teardown() {
        state = .idle
        tearDownOverlay()
        capture.stop()
        latestFrame = nil
        previewFold = 0
        scheduleWatch(interval: 1.0 / 10.0)
    }

    enum ControllerError: LocalizedError {
        case noMetalDevice
        var errorDescription: String? { "This Mac has no Metal-capable GPU." }
    }
}
