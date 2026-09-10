import Foundation
import CoreGraphics
import AppKit

enum ScreenLock {
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return true
        }
        func flag(_ key: String) -> Bool? {
            if let value = session[key] as? Bool { return value }
            if let value = session[key] as? Int { return value != 0 }
            if let value = session[key] as? NSNumber { return value.boolValue }
            return nil
        }

        if flag("CGSSessionScreenIsLocked") == true { return true }
        guard let onConsole = flag(kCGSessionOnConsoleKey as String) else { return true }
        return !onConsole
    }

    static func observe(onLock: @escaping () -> Void, onUnlock: @escaping () -> Void) {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"),
                           object: nil, queue: .main) { _ in onLock() }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                           object: nil, queue: .main) { _ in onUnlock() }
    }
}
