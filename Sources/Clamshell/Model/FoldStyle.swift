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

    /// How far the far edge recedes, in normalised depth. Higher reads as a
    /// wider-angle lens and a more dramatic tilt.
    var perspective: Double

    /// Maximum blur radius in pixels at full fold.
    var blurRadius: Double

    /// How far toward black the image is pulled at full fold, 0...1.
    var darkening: Double

    /// Opacity of the soft shadow that gathers along the hinge, 0...1.
    var shadowStrength: Double

    /// Strength of the sheen that sweeps across the panel as it tilts, 0...1.
    /// Reads as light raking across a glossy screen.
    var sheen: Double

    /// How much the corners are pulled in, 0...1. A little of this sells the
    /// panel as a physical sheet rather than a flat texture.
    var curvature: Double

    static let satin = FoldStyle(
        id: "satin",
        name: "Satin",
        blurb: "Smooth and glossy, with light raking across the panel.",
        perspective: 0.62,
        blurRadius: 14,
        darkening: 0.45,
        shadowStrength: 0.40,
        sheen: 0.55,
        curvature: 0.18
    )

    static let eclipse = FoldStyle(
        id: "eclipse",
        name: "Eclipse",
        blurb: "Deep shadow. The panel falls away into the dark.",
        perspective: 0.78,
        blurRadius: 8,
        darkening: 0.82,
        shadowStrength: 0.85,
        sheen: 0.10,
        curvature: 0.10
    )

    static let glacier = FoldStyle(
        id: "glacier",
        name: "Glacier",
        blurb: "Frosted glass. Everything softens before it goes.",
        perspective: 0.50,
        blurRadius: 34,
        darkening: 0.30,
        shadowStrength: 0.25,
        sheen: 0.30,
        curvature: 0.24
    )

    static let all: [FoldStyle] = [.satin, .eclipse, .glacier]

    static func named(_ id: String) -> FoldStyle {
        all.first { $0.id == id } ?? .satin
    }
}
