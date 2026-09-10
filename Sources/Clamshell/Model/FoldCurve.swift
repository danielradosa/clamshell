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
    /// A cubic ease-in: slow enough at the start that a lid which is merely
    /// tilted looks untouched, but far enough along by the time the lid is
    /// halfway down that the fold is actually seen.
    ///
    /// The curve is constrained by a hardware fact. With `engageAngle` at its
    /// default of 75 degrees, this is what each curve produces:
    ///
    ///     angle     t^5      t^3    smoothstep
    ///        60   0.001    0.013         0.143
    ///        40   0.053    0.171         0.583
    ///        30   0.186    0.364         0.802
    ///        20   0.507    0.665         0.956
    ///        15   0.784    0.864         0.993   <- backlight cutting out
    ///
    /// A quintic puts almost the whole effect below 20 degrees, which is past
    /// the point where the panel starts going dark — so most of the animation
    /// would play on a screen nobody can see. That is why it is not the default.
    ///
    /// TODO(daniel): this is the knob worth playing with. Alternatives, roughly
    /// ordered by how eager they feel:
    ///   - `t * t * t * t * t`    quintic: very late, mostly invisible in practice
    ///   - `t * t`                earlier still than cubic
    ///   - `t * t * (3 - 2 * t)`  smoothstep: eases in AND out. Softer and more
    ///                            mechanical, and visible from about 60 degrees
    ///   - `1 - pow(1 - t, 3)`    ease-out: nearly all the motion up front, then
    ///                            it hangs. Reads as the screen giving way at once
    private static func ease(_ t: Double) -> Double {
        t * t * t
    }
}
