import Foundation

enum FoldCurve {
    static let closedAngle: Double = 12

    static func travel(angle: Double, engageAngle: Double) -> Double {
        let span = max(engageAngle - closedAngle, 1)
        return min(max((engageAngle - angle) / span, 0), 1)
    }

    static func progress(angle: Double, engageAngle: Double) -> Double {
        ease(travel(angle: angle, engageAngle: engageAngle))
    }

    static func softness(angle: Double, engageAngle: Double) -> Double {
        pow(travel(angle: angle, engageAngle: engageAngle), 0.9)
    }

    static func softness(forTravel travel: Double) -> Double {
        pow(min(max(travel, 0), 1), 0.9)
    }

    private static func ease(_ t: Double) -> Double {
        t * t * t
    }
}
