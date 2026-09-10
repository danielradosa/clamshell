import Foundation
import CoreGraphics
import AppKit

/// Whether the login window or lock screen is currently up.
///
/// This matters more here than it looks. Closing the lid sleeps the Mac, and on
/// most Macs opening it again lands on the lock screen. The overlay draws a
/// snapshot of the desktop taken *before* sleep — so showing it there would
/// paint the user's private desktop on top of the lock screen, for anyone
/// holding the machine. The effect is cosmetic; that would not be.
enum ScreenLock {

    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // If the session cannot be read, assume the worst rather than
            // risk drawing the desktop over a lock screen.
            return true
        }
        // These come back as CFBoolean or CFNumber depending on the key and the
        // OS release, and a failed cast would silently read as "unlocked" — the
        // one wrong answer that matters. Accept either representation.
        func flag(_ key: String) -> Bool? {
            if let value = session[key] as? Bool { return value }
            if let value = session[key] as? Int { return value != 0 }
            if let value = session[key] as? NSNumber { return value.boolValue }
            return nil
        }

        if flag("CGSSessionScreenIsLocked") == true { return true }
        // Absent means this session is not on the console at all.
        guard let onConsole = flag(kCGSessionOnConsoleKey as String) else { return true }
        return !onConsole
    }

    /// Observes lock and unlock. These arrive on the distributed notification
    /// centre rather than the workspace one.
    static func observe(onLock: @escaping () -> Void, onUnlock: @escaping () -> Void) {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"),
                           object: nil, queue: .main) { _ in onLock() }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                           object: nil, queue: .main) { _ in onUnlock() }
    }
}
