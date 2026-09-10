import Foundation

/// A named bundle of look parameters for the fold effect.
///
/// Every value is expressed as the amount applied at *full* fold; the renderer
/// scales each one by the current fold progress, so a style is really a set of
/// end points rather than a set of constants.
struct FoldStyle: Equatable, Identifiable, Sendable {

    let id: String
    let name: String
    let blurb: String

    /// Strength of the perspective divide. Higher reads as a wider-angle lens
    /// and a more dramatic tilt as the panel swings away.
    var perspective: Double

    /// Blur reach at full fold, in screen pixels. Converted to a mip level, so
    /// doubling this value costs one extra level and no extra work.
    var blurRadius: Double

    /// How far toward black the image is pulled at full fold, 0...1.
    var darkening: Double

    /// How hard darkness creeps down from the top edge, 0...1.
    var shadowStrength: Double

    /// How hard the corners are pulled to black, 0...1.
    var vignette: Double

    /// Strength of the sheen that sweeps across the panel as it tilts, 0...1.
    var sheen: Double

    /// How much the sheet bows out of plane, 0...1.
    var curvature: Double

    static let satin = FoldStyle(
        id: "satin",
        name: "Satin",
        blurb: "Smooth and glossy, with light raking across the panel.",
        perspective: 0.62,
        blurRadius: 130,
        darkening: 0.30,
        shadowStrength: 0.55,
        vignette: 0.85,
        sheen: 0.45,
        curvature: 0.20
    )

    static let eclipse = FoldStyle(
        id: "eclipse",
        name: "Eclipse",
        blurb: "Deep shadow. The panel falls away into the dark.",
        perspective: 0.78,
        blurRadius: 96,
        darkening: 0.55,
        shadowStrength: 0.80,
        vignette: 1.0,
        sheen: 0.08,
        curvature: 0.12
    )

    static let glacier = FoldStyle(
        id: "glacier",
        name: "Glacier",
        blurb: "Frosted glass. Everything softens before it goes.",
        perspective: 0.52,
        blurRadius: 260,
        darkening: 0.22,
        shadowStrength: 0.40,
        vignette: 0.65,
        sheen: 0.25,
        curvature: 0.26
    )

    static let all: [FoldStyle] = [.satin, .eclipse, .glacier]

    static func named(_ id: String) -> FoldStyle {
        all.first { $0.id == id } ?? .satin
    }
}
