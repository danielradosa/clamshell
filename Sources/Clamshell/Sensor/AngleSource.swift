import Foundation
import QuartzCore

/// Supplies a smoothed hinge angle, from real hardware when present and from a
/// scripted animation when not.
///
/// The raw sensor quantises to whole degrees, so feeding it straight into the
/// renderer makes the fold visibly step. A critically damped spring removes the
/// stair-stepping without the overshoot a plain spring would add, and without
/// the lag a long moving average would add.
final class AngleSource {

    enum Mode {
        /// Follow the physical lid.
        case sensor
        /// Follow a value the user drags in Settings.
        case manual(Double)
        /// Sweep open and closed on a loop, for demos and for Macs with no sensor.
        case demo
    }

    private let sensor = LidAngleSensor()
    private var springPosition: Double
    private var springVelocity: Double = 0
    private var demoPhase: Double = 0
    private var lastTick: CFTimeInterval

    /// Angle the lid rests at when fully open; used as the start value and as
    /// the fallback whenever a read fails.
    static let restingAngle: Double = 100

    var mode: Mode = .sensor

    /// True when this Mac exposes a usable lid angle sensor.
    var hasSensor: Bool { sensor.isAvailable }

    /// The most recent raw reading, before smoothing. Settings shows this so the
    /// user can see the hardware working.
    private(set) var rawAngle: Double = AngleSource.restingAngle

    /// How fast the lid is closing, in degrees per second. Positive means the
    /// lid is coming down. A person closing a MacBook moves at roughly 100 to
    /// 300 degrees per second, so this separates a deliberate close from a lid
    /// that simply happens to be resting at a shallow angle.
    private(set) var closingVelocity: Double = 0

    /// Smoothed hinge angle in degrees.
    var angle: Double { springPosition }

    init() {
        springPosition = Self.restingAngle
        lastTick = CACurrentMediaTime()
    }

    /// Advances the spring toward the current target. Call once per frame.
    func tick() {
        let now = CACurrentMediaTime()
        // Clamp dt so a stalled frame or a wake-from-sleep cannot fling the spring.
        let dt = min(max(now - lastTick, 1.0 / 240.0), 1.0 / 20.0)
        lastTick = now

        let target = currentTarget(dt: dt)
        // Smooth the derivative too: a 1-degree quantisation step across a short
        // frame would otherwise read as a huge instantaneous velocity.
        let instantaneous = (rawAngle - target) / dt
        closingVelocity += (instantaneous - closingVelocity) * min(dt * 8, 1)
        rawAngle = target
        integrateSpring(toward: target, dt: dt)
    }

    private func currentTarget(dt: Double) -> Double {
        switch mode {
        case .sensor:
            return sensor.currentAngle() ?? rawAngle
        case .manual(let value):
            return value
        case .demo:
            demoPhase += dt / 3.5
            // Triangle wave between shut and fully open, eased at the turns so the
            // demo reads as a hand closing a lid rather than a linear ramp.
            let t = demoPhase.truncatingRemainder(dividingBy: 1.0)
            let triangle = t < 0.5 ? t * 2 : (1 - t) * 2
            let eased = triangle * triangle * (3 - 2 * triangle)
            return 5 + eased * (Self.restingAngle - 5)
        }
    }

    /// Critically damped spring: the fastest approach to the target that never
    /// overshoots. `stiffness` is the only knob; damping is derived from it.
    private func integrateSpring(toward target: Double, dt: Double) {
        let stiffness: Double = 220
        let damping = 2 * sqrt(stiffness)
        let acceleration = stiffness * (target - springPosition) - damping * springVelocity
        springVelocity += acceleration * dt
        springPosition += springVelocity * dt
    }

    /// Snaps the spring to a value, skipping the animation. Used when the effect
    /// is re-enabled so it does not sweep in from a stale position.
    func reset(to value: Double? = nil) {
        let target = value ?? sensor.currentAngle() ?? Self.restingAngle
        springPosition = target
        springVelocity = 0
        closingVelocity = 0
        rawAngle = target
        lastTick = CACurrentMediaTime()
    }
}
