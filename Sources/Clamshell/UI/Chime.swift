import AppKit

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
