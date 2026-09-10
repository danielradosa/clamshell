import Foundation
import Combine

final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Key {
        static let enabled = "enabled"
        static let styleID = "styleID"
        static let engageAngle = "engageAngle"
        static let perspectiveScale = "perspectiveScale"
        static let blurScale = "blurScale"
        static let shadowScale = "shadowScale"
        static let edgeScale = "edgeScale"
        static let soundEnabled = "soundEnabled"
        static let unfoldDuration = "unfoldDuration"
    }

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }

    @Published var styleID: String { didSet { defaults.set(styleID, forKey: Key.styleID) } }

    @Published var engageAngle: Double { didSet { defaults.set(engageAngle, forKey: Key.engageAngle) } }

    @Published var perspectiveScale: Double { didSet { defaults.set(perspectiveScale, forKey: Key.perspectiveScale) } }
    @Published var blurScale: Double { didSet { defaults.set(blurScale, forKey: Key.blurScale) } }
    @Published var shadowScale: Double { didSet { defaults.set(shadowScale, forKey: Key.shadowScale) } }
    @Published var edgeScale: Double { didSet { defaults.set(edgeScale, forKey: Key.edgeScale) } }

    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Key.soundEnabled) } }

    @Published var unfoldDuration: Double { didSet { defaults.set(unfoldDuration, forKey: Key.unfoldDuration) } }

    var style: FoldStyle {
        var s = FoldStyle.named(styleID)
        s.perspective *= perspectiveScale
        s.blurRadius *= blurScale
        s.shadowStrength *= shadowScale
        s.edgeSoftness *= edgeScale
        return s
    }

    func resetToDefaults() {
        for key in [Key.enabled, Key.styleID, Key.engageAngle, Key.perspectiveScale,
                    Key.blurScale, Key.shadowScale, Key.edgeScale, Key.soundEnabled,
                    Key.unfoldDuration] {
            defaults.removeObject(forKey: key)
        }
        enabled = defaults.bool(forKey: Key.enabled)
        styleID = defaults.string(forKey: Key.styleID) ?? FoldStyle.eclipse.id
        engageAngle = defaults.double(forKey: Key.engageAngle)
        perspectiveScale = defaults.double(forKey: Key.perspectiveScale)
        blurScale = defaults.double(forKey: Key.blurScale)
        shadowScale = defaults.double(forKey: Key.shadowScale)
        edgeScale = defaults.double(forKey: Key.edgeScale)
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        unfoldDuration = defaults.double(forKey: Key.unfoldDuration)
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.styleID: FoldStyle.eclipse.id,
            Key.engageAngle: 100.0,
            Key.perspectiveScale: 1.0,
            Key.blurScale: 1.0,
            Key.shadowScale: 1.0,
            Key.edgeScale: 1.0,
            Key.soundEnabled: false,
            Key.unfoldDuration: 1.0,
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        styleID = defaults.string(forKey: Key.styleID) ?? FoldStyle.eclipse.id
        engageAngle = defaults.double(forKey: Key.engageAngle)
        perspectiveScale = defaults.double(forKey: Key.perspectiveScale)
        blurScale = defaults.double(forKey: Key.blurScale)
        shadowScale = defaults.double(forKey: Key.shadowScale)
        edgeScale = defaults.double(forKey: Key.edgeScale)
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        unfoldDuration = defaults.double(forKey: Key.unfoldDuration)
    }
}
