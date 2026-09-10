import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// Determines whether this app can actually capture the screen.
///
/// `CGPreflightScreenCaptureAccess()` is advisory and answers false in cases
/// where capture in fact works, so it is not used as the authority here. The
/// authority is ScreenCaptureKit itself: if it hands back a list of displays,
/// capture works, and if it refuses with `SCStreamErrorUserDeclined` it does
/// not. Asking the thing you actually need beats asking a proxy for it.
enum ScreenPermission {

    enum State: Equatable {
        /// Capture works right now.
        case granted
        /// The user has not answered, or has declined.
        case denied
        /// Capture is unavailable for some other reason.
        case unavailable(String)
    }

    /// Asks ScreenCaptureKit whether it will actually give us the screen.
    static func check() async -> State {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            return content.displays.isEmpty ? .unavailable("No capturable display.") : .granted
        } catch {
            let nsError = error as NSError
            // -3801 is SCStreamErrorUserDeclined, which covers both "declined"
            // and "never asked" — macOS does not distinguish them here.
            if nsError.code == -3801 { return .denied }
            return .unavailable(error.localizedDescription)
        }
    }

    /// Triggers the system prompt. macOS shows it at most once per app, so a
    /// false return means the user must go to System Settings by hand.
    @discardableResult
    static func requestFromSystem() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Relaunches the app. macOS does not hand a running process a Screen
    /// Recording grant that was made after it started, so a restart is the only
    /// reliable way to pick one up.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
