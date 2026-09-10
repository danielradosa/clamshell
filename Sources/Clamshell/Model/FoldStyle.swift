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

    /// How far the top edge is drawn in, as a fraction of width, at full fold.
    /// Deliberately small: the lid is physically tilting already, and warping the
    /// image hard on top of that shrinks it into a black frame instead of
    /// reading as depth.
    var perspective: Double

    /// Blur reach at full fold, in screen pixels. Converted to a mip level, so
    /// doubling this value costs one extra level and no extra work.
    var blurRadius: Double

    /// How far toward black the image is pulled at full fold, 0...1.
    var darkening: Double

    /// Opacity of the soft shadow that gathers along the far edge, 0...1.
    var shadowStrength: Double

    /// Strength of the sheen that sweeps across the panel as it tilts, 0...1.
    var sheen: Double

    /// How much the sheet bows out of plane, 0...1.
    var curvature: Double

    static let satin = FoldStyle(
        id: "satin",
        name: "Satin",
        blurb: "Smooth and glossy, with light raking across the panel.",
        perspective: 0.14,
        blurRadius: 130,
        darkening: 0.14,
        shadowStrength: 0.16,
        sheen: 0.45,
        curvature: 0.35
    )

    static let eclipse = FoldStyle(
        id: "eclipse",
        name: "Eclipse",
        blurb: "Deep shadow. The panel falls away into the dark.",
        perspective: 0.18,
        blurRadius: 96,
        darkening: 0.38,
        shadowStrength: 0.40,
        sheen: 0.08,
        curvature: 0.20
    )

    static let glacier = FoldStyle(
        id: "glacier",
        name: "Glacier",
        blurb: "Frosted glass. Everything softens before it goes.",
        perspective: 0.10,
        blurRadius: 260,
        darkening: 0.08,
        shadowStrength: 0.10,
        sheen: 0.25,
        curvature: 0.45
    )

    static let all: [FoldStyle] = [.satin, .eclipse, .glacier]

    static func named(_ id: String) -> FoldStyle {
        all.first { $0.id == id } ?? .satin
    }
}
