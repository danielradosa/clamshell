import Foundation

struct FoldStyle: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let blurb: String

    var perspective: Double

    var blurRadius: Double

    var darkening: Double

    var shadowStrength: Double

    var vignette: Double

    var sheen: Double

    var curvature: Double

    static let satin = FoldStyle(
        id: "satin",
        name: "Satin",
        blurb: "Smooth and glossy, with light raking across the panel.",
        perspective: 0.85,
        blurRadius: 300,
        darkening: 0.35,
        shadowStrength: 0.75,
        vignette: 0.90,
        sheen: 0.40,
        curvature: 0.22
    )

    static let eclipse = FoldStyle(
        id: "eclipse",
        name: "Eclipse",
        blurb: "Deep shadow. The panel falls away into the dark.",
        perspective: 1.00,
        blurRadius: 380,
        darkening: 0.60,
        shadowStrength: 1.00,
        vignette: 1.00,
        sheen: 0.08,
        curvature: 0.14
    )

    static let glacier = FoldStyle(
        id: "glacier",
        name: "Glacier",
        blurb: "Frosted glass. Everything softens before it goes.",
        perspective: 0.75,
        blurRadius: 620,
        darkening: 0.25,
        shadowStrength: 0.60,
        vignette: 0.75,
        sheen: 0.22,
        curvature: 0.28
    )

    static let all: [FoldStyle] = [.satin, .eclipse, .glacier]

    static func named(_ id: String) -> FoldStyle {
        all.first { $0.id == id } ?? .satin
    }
}
