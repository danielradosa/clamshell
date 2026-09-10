import Foundation

enum FoldCurve {
    static let closedAngle: Double = 12

    static func progress(angle: Double, engageAngle: Double) -> Double {
        let span = max(engageAngle - closedAngle, 1)
        let linear = (engageAngle - angle) / span
        let t = min(max(linear, 0), 1)
        return ease(t)
    }

    private static func ease(_ t: Double) -> Double {
        t * t * t
    }
}
