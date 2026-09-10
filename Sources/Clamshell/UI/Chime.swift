import AppKit

/// The soft click played when the lid opens far enough to clear the effect.
///
/// Uses a stock system sound rather than a bundled audio file. A SwiftPM
/// executable has no asset catalog and `Bundle.module` needs a resource bundle
/// copied next to the binary; leaning on a sound macOS already ships sidesteps
/// both and keeps the app a single self-contained executable.
enum Chime {

    private static let sound: NSSound? = {
        let candidates = ["Tink", "Pop", "Morse"]
        for name in candidates {
            if let sound = NSSound(named: NSSound.Name(name)) { return sound }
        }
        return nil
    }()

    static func playClear() {
        guard let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.volume = 0.35
        sound.play()
    }
}
