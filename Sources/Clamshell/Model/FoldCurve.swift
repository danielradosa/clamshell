import Foundation

/// Maps a physical hinge angle onto fold progress, the single 0...1 number that
/// drives every visual parameter in the renderer.
///
/// This is the feel of the whole app. The hardware reports a linear angle, but a
/// linear response looks wrong: the first few degrees of travel from a wide-open
/// lid should barely register, while the last stretch before the display cuts out
/// should be where most of the motion happens. The curve is what creates that.
///
/// Two facts about the hardware constrain the shape:
///   - A MacBook rests open somewhere around 90-130 degrees.
///   - The panel backlight cuts out near 10-15 degrees, so anything below that is
///     never actually seen. Spending curve range down there wastes the effect.
enum FoldCurve {

    /// Angle below which the lid is treated as shut. The display is already dark
    /// by this point on real hardware.
    static let closedAngle: Double = 12

    /// Converts a hinge angle in degrees into fold progress.
    ///
    /// - Parameters:
    ///   - angle: Smoothed hinge angle in degrees. Larger means more open.
    ///   - engageAngle: Angle at and above which the effect is fully cleared.
    ///     User-configurable in Settings; defaults to 75 degrees.
    /// - Returns: 0 when the lid is open enough that nothing should happen,
    ///   rising to 1 when the lid is shut.
    static func progress(angle: Double, engageAngle: Double) -> Double {
        // Guard against a user dragging engageAngle down onto closedAngle.
        let span = max(engageAngle - closedAngle, 1)
        let linear = (engageAngle - angle) / span
        let t = min(max(linear, 0), 1)
        return ease(t)
    }

    /// Shapes the normalised 0...1 travel.
    ///
    /// TODO(daniel): this is the tuning knob worth playing with. The default is a
    /// quintic ease-in — deliberately slow to start so a lid that is merely tilted
    /// looks untouched, then accelerating hard through the final stretch.
    ///
    /// Alternatives worth trying, in rough order of how different they feel:
    ///   - `t * t`                        gentler, effect shows up much earlier
    ///   - `t * t * t`                    the middle ground
    ///   - `t * t * (3 - 2 * t)`          smoothstep: eases in AND out, feels softer
    ///                                    and more mechanical, less like gravity
    ///   - `1 - pow(1 - t, 3)`            ease-out: almost all the motion up front,
    ///                                    then it hangs. Reads as the screen giving
    ///                                    way immediately.
    ///   - `pow(t, 1.5)`                  barely-curved, closest to linear
    private static func ease(_ t: Double) -> Double {
        t * t * t * t * t
    }
}
