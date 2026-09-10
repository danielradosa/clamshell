import Foundation
import QuartzCore

final class AngleSource {
    enum Mode {
        case sensor
        case manual(Double)
        case demo
    }

    private let sensor = LidAngleSensor()
    private var springPosition: Double
    private var springVelocity: Double = 0
    private var demoPhase: Double = 0
    private var lastTick: CFTimeInterval

    static let restingAngle: Double = 100

    private static let teleportThreshold: Double = 25

    private(set) var didTeleport = false

    func consumeTeleport() -> Bool {
        defer { didTeleport = false }
        return didTeleport
    }

    var mode: Mode = .sensor

    var hasSensor: Bool { sensor.isAvailable }

    private(set) var rawAngle: Double = AngleSource.restingAngle

    private(set) var closingVelocity: Double = 0

    var angle: Double { springPosition }

    init() {
        springPosition = Self.restingAngle
        lastTick = CACurrentMediaTime()
    }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 240.0), 1.0 / 20.0)
        lastTick = now

        let target = currentTarget(dt: dt)

        if abs(target - rawAngle) > Self.teleportThreshold {
            rawAngle = target
            springPosition = target
            springVelocity = 0
            closingVelocity = 0
            didTeleport = true
            return
        }

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
            let t = demoPhase.truncatingRemainder(dividingBy: 1.0)
            let triangle = t < 0.5 ? t * 2 : (1 - t) * 2
            let eased = triangle * triangle * (3 - 2 * triangle)
            return 5 + eased * (Self.restingAngle - 5)
        }
    }

    private func integrateSpring(toward target: Double, dt: Double) {
        let stiffness: Double = 220
        let damping = 2 * sqrt(stiffness)
        let acceleration = stiffness * (target - springPosition) - damping * springVelocity
        springVelocity += acceleration * dt
        springPosition += springVelocity * dt
    }

    func reset(to value: Double? = nil) {
        let target = value ?? sensor.currentAngle() ?? Self.restingAngle
        springPosition = target
        springVelocity = 0
        closingVelocity = 0
        rawAngle = target
        lastTick = CACurrentMediaTime()
    }
}
