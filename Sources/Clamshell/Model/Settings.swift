import Foundation
import Combine

/// User-facing preferences, persisted in UserDefaults and observable by SwiftUI.
///
/// The style presets supply the baseline look; the three intensity sliders are
/// multipliers on top, so a user can keep a preset's character while dialling it
/// up or down. Storing multipliers rather than absolute values means switching
/// presets does not silently discard the user's tuning.
final class Settings: ObservableObject {

    static let shared = Settings()

    private enum Key {
        static let enabled = "enabled"
        static let styleID = "styleID"
        static let engageAngle = "engageAngle"
        static let perspectiveScale = "perspectiveScale"
        static let blurScale = "blurScale"
        static let shadowScale = "shadowScale"
        static let soundEnabled = "soundEnabled"
        static let unfoldDuration = "unfoldDuration"
    }

    /// Master on/off for the effect.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }

    /// Which preset is active.
    @Published var styleID: String { didSet { defaults.set(styleID, forKey: Key.styleID) } }

    /// Hinge angle above which the effect is fully cleared. Below it the fold
    /// ramps in as the lid comes down.
    @Published var engageAngle: Double { didSet { defaults.set(engageAngle, forKey: Key.engageAngle) } }

    @Published var perspectiveScale: Double { didSet { defaults.set(perspectiveScale, forKey: Key.perspectiveScale) } }
    @Published var blurScale: Double { didSet { defaults.set(blurScale, forKey: Key.blurScale) } }
    @Published var shadowScale: Double { didSet { defaults.set(shadowScale, forKey: Key.shadowScale) } }

    /// Play a soft click when the lid opens far enough to clear the effect.
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Key.soundEnabled) } }

    /// Seconds the opening animation runs for.
    ///
    /// The unfold is played on its own clock rather than tracked from the hinge,
    /// because a lid is opened far faster than the panel can light up. This is
    /// how long that animation lasts.
    @Published var unfoldDuration: Double { didSet { defaults.set(unfoldDuration, forKey: Key.unfoldDuration) } }

    /// The active preset with the user's multipliers already applied.
    var style: FoldStyle {
        var s = FoldStyle.named(styleID)
        s.perspective *= perspectiveScale
        s.blurRadius *= blurScale
        s.shadowStrength *= shadowScale
        return s
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.styleID: FoldStyle.satin.id,
            Key.engageAngle: 75.0,
            Key.perspectiveScale: 1.0,
            Key.blurScale: 1.0,
            Key.shadowScale: 1.0,
            Key.soundEnabled: true,
            Key.unfoldDuration: 0.75,
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        styleID = defaults.string(forKey: Key.styleID) ?? FoldStyle.satin.id
        engageAngle = defaults.double(forKey: Key.engageAngle)
        perspectiveScale = defaults.double(forKey: Key.perspectiveScale)
        blurScale = defaults.double(forKey: Key.blurScale)
        shadowScale = defaults.double(forKey: Key.shadowScale)
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        unfoldDuration = defaults.double(forKey: Key.unfoldDuration)
    }
}
