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
    private var latestFrame: MTLTexture?
    private var watchTimer: Timer?
    private var state: State = .idle
    private var cancellables = Set<AnyCancellable>()
    private var wasEngaged = false

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

        capture.onFrame = { [weak self] texture in
            // Delivered on the capture queue; hop to main where rendering lives.
            Task { @MainActor in self?.latestFrame = texture }
        }
        capture.onFailure = { [weak self] _ in
            Task { @MainActor in self?.teardown() }
        }

        // If the sensor is missing, fall straight into the looping demo so the
        // app is still worth running on a desktop Mac.
        if !angleSource.hasSensor { angleSource.mode = .demo }

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
            } else if fold > 0.001 {
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

    private func startCapture() {
        guard ScreenCapture.hasPermission else { return }
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
    }

    private func tearDownOverlay() {
        overlay?.metalView.onFrame = nil
        overlay?.orderOut(nil)
        overlay = nil
    }

    private func drawFrame(into layer: CAMetalLayer) {
        guard state == .active, let source = latestFrame else { return }
        angleSource.tick()
        let fold = FoldCurve.progress(angle: angleSource.angle, engageAngle: settings.engageAngle)
        previewFold = fold
        guard let drawable = layer.nextDrawable() else { return }
        renderer.render(source: source, fold: fold, style: settings.style, drawable: drawable)
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
