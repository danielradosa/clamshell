import AppKit
import Metal
import Combine

/// Coordinates the sensor, the capture stream, the renderer and the overlay.
///
/// Three states keep an app that is idle most of the day close to free:
///
///   - `idle`    the lid is open well past the engage angle. Poll the sensor a
///               few times a second and nothing else.
///   - `armed`   the lid has come down near the engage angle, or has started
///               moving. Start the capture stream now, because starting one
///               takes long enough that doing it at the moment of engagement
///               would drop the opening frames.
///   - `active`  the fold is visible. Overlay on screen, rendering every frame.
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

    /// A private copy of the last desktop frame, owned by us.
    ///
    /// This is what makes the opening animation possible. Closing the lid puts
    /// the Mac to sleep, which tears down the capture stream; on wake the
    /// display lights up around 10 to 15 degrees, well before a fresh stream can
    /// be started and deliver a frame. Without something to draw, the whole
    /// unfold would be missed and the screen would simply snap on. The desktop
    /// has not changed during sleep, so the pre-sleep frame is not merely a
    /// stand-in — it is the correct image.
    private var snapshot: MTLTexture?

    /// How far above the engage angle the capture stream spins up.
    ///
    /// Kept tight. A generous margin would leave the capture stream running all
    /// day for anyone who works with the lid at a shallow angle, which is the
    /// common case. Motion arming below covers the lead time instead.
    private let armMargin: Double = 15

    /// Closing speed, in degrees per second, that arms the stream regardless of
    /// angle. Hands close a lid an order of magnitude faster than this.
    private let armVelocity: Double = 15

    /// Extra margin before disarming, to stop the stream flapping.
    private let disarmHysteresis: Double = 12

    /// Fold at which the overlay comes on screen, and the lower one at which it
    /// goes away again.
    ///
    /// Two different values on purpose. A single threshold sits exactly where
    /// the reading is noisiest, so the overlay was being shown and hidden
    /// repeatedly as the value crossed back and forth — visible as a flicker
    /// right at the moment the effect should be settling.
    private let engageFold: Double = 0.004
    private let clearFold: Double = 0.0004

    /// How long the opening animation runs, in seconds.
    ///
    /// The unfold cannot simply track the hinge. A lid is thrown open in a
    /// couple of tenths of a second and the panel does not light up until it is
    /// already past fifteen degrees, so a sensor-following unfold has perhaps
    /// two tenths of visible travel left — which reads as a blink, not an
    /// animation. So the opening is played on its own clock, and eased back onto
    /// the real angle by the end.
    private var unfoldDuration: TimeInterval { settings.unfoldDuration }

    private var unfoldStart: Date?
    private var unfoldFrom: Double = 1

    /// Previous tick's angle, used to notice the lid coming back up.
    private var lastSeenAngle: Double = AngleSource.restingAngle

    /// Set when the user pauses from the menu bar or with Escape.
    var isPaused = false { didSet { if isPaused { teardown() } else { angleSource.reset() } } }

    /// Set by the app delegate once the permission check has actually answered.
    var isCaptureAllowed = false

    var hasSensor: Bool { angleSource.hasSensor }
    var currentRawAngle: Double { angleSource.rawAngle }

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
            Task { @MainActor in self?.handleCaptureFailure() }
        }

        // A Mac with no lid sensor must sit still by default. Falling back to
        // the looping demo here would mean an app that throws a fullscreen
        // overlay across the screen every few seconds, forever.
        if !angleSource.hasSensor {
            angleSource.mode = .manual(AngleSource.restingAngle)
        }

        settings.$enabled
            .sink { [weak self] enabled in if !enabled { self?.teardown() } }
            .store(in: &cancellables)

        observeSleepAndWake()
        observeScreenLock()
        startWatching()
    }

    func setMode(_ mode: AngleSource.Mode) {
        angleSource.mode = mode
        angleSource.reset()
    }

    /// Plays one close-and-open sweep. Used from the menu so the effect can be
    /// seen on demand, including on Macs with no sensor.
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

    // MARK: - Sleep and wake

    /// Closing the lid sleeps the Mac, so the interesting half of the effect —
    /// the unfold as the lid opens — happens across a sleep boundary.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter

        // Closing the lid does not always sleep the whole Mac — an app holding a
        // power assertion, or an external display, can leave the system awake
        // with only the panel switched off. Both paths have to be handled, or
        // the unfold works in one case and not the other.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.prepareForSleep() }
            }
        }
        // Both fire on lid-open; whichever lands first does the work.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleWake() }
            }
        }
    }

    /// The overlay must never be on screen over a lock screen, and the snapshot
    /// of the desktop must not survive a lock.
    private func observeScreenLock() {
        ScreenLock.observe(onLock: { [weak self] in
            Task { @MainActor in
                self?.trace("screen locked — dropping snapshot and hiding")
                self?.hideOverlay()
                self?.snapshot = nil
                self?.latestFrame = nil
                self?.state = .idle
            }
        }, onUnlock: { [weak self] in
            Task { @MainActor in self?.angleSource.reset() }
        })
    }

    private func prepareForSleep() {
        trace("sleeping — overlay down, snapshot kept for the unfold")
        // The overlay must not be left on screen across a sleep, or the desktop
        // is hidden behind a frozen image on wake. The snapshot is deliberately
        // kept: it is what the unfold draws before a fresh stream can deliver.
        overlay?.hide()
        escapeHotKey.disarm()
        state = .armed
        capture.stop()
        latestFrame = nil
    }

    private func handleWake() {
        guard settings.enabled, !isPaused, isCaptureAllowed else { return }
        guard !ScreenLock.isLocked else {
            // Woken to a lock screen. Drop the pre-sleep desktop and wait for
            // the unlock, which resets the angle spring.
            trace("wake: locked — discarding snapshot")
            snapshot = nil
            state = .idle
            scheduleWatch(interval: 1.0 / 10.0)
            return
        }

        // Start the stream immediately rather than waiting for the watch loop —
        // every millisecond here is a millisecond of the unfold that is missed.
        startCapture()

        // Jump the spring to where the lid actually is. Letting it ease over
        // from its pre-sleep position would play a fold the user never made.
        angleSource.reset()
        scheduleWatch(interval: 1.0 / 120.0)

        let sensorFold = FoldCurve.progress(
            angle: angleSource.angle, engageAngle: settings.engageAngle
        )
        trace(String(format: "wake: angle %.1f fold %.3f snapshot %@",
                     angleSource.angle, sensorFold, snapshot != nil ? "yes" : "no"))

        guard snapshot != nil else {
            state = .armed
            return
        }
        // Play the opening animation regardless of where the lid has already
        // got to. By the time the panel lights up the lid is usually most of
        // the way open, so gating this on the sensor would skip it entirely.
        beginUnfold(from: sensorFold)
        state = .active
        showOverlay()
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
        let fold = currentFold()
        previewFold = fold

        let closingFast = angleSource.closingVelocity > armVelocity

        // Belt and braces for the opening animation. Whether the lid close put
        // the whole Mac to sleep, only the panel, or nothing at all, depends on
        // power assertions and external displays — and the matching wake
        // notification does not always arrive. Seeing the angle itself come back
        // up from shut is the one signal that is always there.
        let wasShut = lastSeenAngle < FoldCurve.closedAngle + 8
        let isOpening = angle > FoldCurve.closedAngle + 8
        if wasShut, isOpening, unfoldStart == nil, snapshot != nil,
           !isPaused, settings.enabled, !ScreenLock.isLocked {
            trace(String(format: "lid opening observed (%.1f -> %.1f), starting unfold",
                         lastSeenAngle, angle))
            beginUnfold(from: 1)
            if state != .active { transition(to: .active) }
        }
        lastSeenAngle = angle
        _ = angleSource.consumeTeleport()

        switch state {
        case .idle:
            if angle < engage + armMargin || closingFast { transition(to: .armed) }
        case .armed:
            if angle > engage + armMargin + disarmHysteresis && !closingFast {
                transition(to: .idle)
            } else if fold > engageFold, hasSomethingToDraw {
                transition(to: .active)
            }
        case .active:
            // Never end the state mid-animation; the unfold owns the fold value
            // until it finishes.
            if fold < clearFold, unfoldStart == nil { transition(to: .armed) }
        }

        trackClearSound(fold: fold)
    }

    /// Appends to ~/Library/Logs/Clamshell-trace.log.
    ///
    /// Always on, and always to a file. An earlier version wrote to stderr,
    /// which is useless for this app: the interesting events happen either side
    /// of a sleep, and asking someone to keep a terminal capturing across a lid
    /// close loses the output at exactly the moment it matters.
    private static let traceURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Clamshell-trace.log")

    private static let traceStart = Date()

    private func trace(_ message: String) {
        let stamp = String(format: "%7.3f", Date().timeIntervalSince(Self.traceStart))
        let line = "[\(stamp)] \(message)\n"
        if Self.isTracingToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.traceURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.traceURL)
        }
    }

    private static let isTracingToStderr =
        ProcessInfo.processInfo.environment["CLAMSHELL_TRACE"] == "1"

    private func transition(to next: State) {
        guard next != state else { return }
        let previous = state
        state = next
        trace("state \(previous) -> \(next)")

        switch next {
        case .idle:
            hideOverlay()
            capture.stop()
            latestFrame = nil
            scheduleWatch(interval: 1.0 / 10.0)

        case .armed:
            if previous == .idle { startCapture() }
            if previous == .active { hideOverlay() }
            scheduleWatch(interval: 1.0 / 120.0)

        case .active:
            showOverlay()
            scheduleWatch(interval: 1.0 / 120.0)
        }
    }

    /// Anything at all to render — a live frame, or the pre-sleep snapshot.
    private var hasSomethingToDraw: Bool { latestFrame != nil || snapshot != nil }

    /// Fold progress, with the opening animation blended in when one is running.
    ///
    /// The blend eases from wherever the fold was when the lid opened onto
    /// whatever the sensor currently says, so a lid opened only halfway settles
    /// at the right amount of fold instead of unfolding flat and snapping back.
    private func currentFold() -> Double {
        let sensorFold = FoldCurve.progress(
            angle: angleSource.angle, engageAngle: settings.engageAngle
        )
        guard let start = unfoldStart else { return sensorFold }

        let elapsed = Date().timeIntervalSince(start)
        guard elapsed < unfoldDuration else {
            unfoldStart = nil
            return sensorFold
        }

        // Ease out: moves off quickly, then settles. A lid springs open and
        // comes to rest; it does not glide at a constant rate.
        let progress = elapsed / unfoldDuration
        let eased = 1 - pow(1 - progress, 3)
        return unfoldFrom + (sensorFold - unfoldFrom) * eased
    }

    private func beginUnfold(from fold: Double) {
        unfoldFrom = max(fold, 0.85)
        unfoldStart = Date()
        trace(String(format: "unfold started from %.3f over %.2fs", unfoldFrom, unfoldDuration))
    }

    private func startCapture() {
        guard isCaptureAllowed else { return }
        let displayID = displayIDForOverlay()
        Task { try? await capture.start(on: displayID) }
    }

    private func handleCaptureFailure() {
        // The stream dies whenever the panel switches off, which is exactly the
        // moment before the unfold needs to be drawn. Drop the live frame, keep
        // the snapshot.
        trace("capture stream ended")
        latestFrame = nil
        if state == .active { transition(to: .armed) }
    }

    private func displayIDForOverlay() -> CGDirectDisplayID {
        // The built-in display is the one with a lid, so prefer it.
        let screen = builtInScreen
        let number = screen?.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        return number?.uint32Value ?? CGMainDisplayID()
    }

    private var builtInScreen: NSScreen? {
        NSScreen.screens.first { $0.localizedName.contains("Built-in") } ?? NSScreen.main
    }

    // MARK: - Overlay

    /// The window is built once and kept. Rebuilding it per engagement made the
    /// effect flicker and cost a frame of black every time it appeared.
    private func ensureOverlay() -> OverlayWindow? {
        if let overlay { return overlay }
        guard let screen = builtInScreen else { return nil }
        let window = OverlayWindow(screen: screen, device: device)
        window.metalView.onFrame = { [weak self] layer in
            MainActor.assumeIsolated { self?.drawFrame(into: layer) }
        }
        overlay = window
        trace("overlay WINDOW CREATED (should happen exactly once)")
        return window
    }

    private func showOverlay() {
        // Last line of defence. The lock notification should already have
        // cleared everything, but the overlay draws desktop contents and must
        // not appear over a lock screen under any circumstance.
        guard !ScreenLock.isLocked else {
            trace("refusing to show overlay: screen is locked")
            snapshot = nil
            state = .armed
            return
        }
        guard let overlay = ensureOverlay() else { return }
        overlay.show()
        trace("overlay shown")
        // Escape pauses while the fold is on screen, and only while it is.
        escapeHotKey.arm { [weak self] in
            guard let self, !self.isPaused else { return }
            self.isPaused = true
        }
    }

    private func hideOverlay() {
        escapeHotKey.disarm()
        if overlay?.isVisible == true { trace("overlay hidden") }
        overlay?.hide()
    }

    private func drawFrame(into layer: CAMetalLayer) {
        // Prefer a live frame; fall back to the snapshot, which is what carries
        // the unfold immediately after a wake.
        guard let source = latestFrame?.texture ?? snapshot else { return }
        let fold = currentFold()
        guard let drawable = layer.nextDrawable() else { return }
        renderer.render(source: source, fold: fold, style: settings.style, drawable: drawable)

        // Keep the snapshot current while the lid is closing, so whatever the
        // screen looked like just before sleep is what unfolds on wake.
        if let live = latestFrame?.texture, fold > 0.25 {
            let hadSnapshot = snapshot != nil
            snapshot = renderer.copy(live, into: snapshot)
            if !hadSnapshot, snapshot != nil {
                trace("snapshot taken (\(live.width)x\(live.height)) — this is what unfolds on wake")
            }
        }
    }

    // MARK: - Sound

    private func trackClearSound(fold: Double) {
        let engaged = fold > engageFold
        defer { wasEngaged = engaged }
        guard wasEngaged, !engaged, settings.soundEnabled else { return }
        Chime.playClear()
    }

    private func teardown() {
        state = .idle
        hideOverlay()
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
