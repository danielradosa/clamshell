import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: FoldController?
    private var menuBar: MenuBarController?

    private enum Key {
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let hasRequestedCapture = "hasRequestedScreenCapture"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--diagnose") {
            Task {
                await Diagnostics.run()
                NSApp.terminate(nil)
            }
            return
        }

        // Agent app: no Dock icon, no menu bar of its own. LSUIElement in the
        // Info.plist covers this too, but setting it here means the app behaves
        // correctly even when run straight out of the build directory.
        NSApp.setActivationPolicy(.accessory)

        do {
            let controller = try FoldController()
            self.controller = controller
            self.menuBar = MenuBarController(controller: controller)
        } catch {
            presentFatal(error)
            return
        }

        Task { await establishCapturePermission() }
    }

    /// Works out whether capture is actually possible, and shows the user
    /// something useful either way.
    ///
    /// Nothing here blocks. An earlier version put up a modal alert on every
    /// launch where the permission looked missing, driven by a check that was
    /// not reliable — so the alert appeared even for users who had granted the
    /// permission, every single time they opened the app.
    private func establishCapturePermission() async {
        let defaults = UserDefaults.standard
        let state = await ScreenPermission.check()

        switch state {
        case .granted:
            controller?.isCaptureAllowed = true
            menuBar?.needsPermission = false
            // Give a first-time user something to look at. Without this the app
            // launches into a single menu bar icon and looks like it did nothing.
            if !defaults.bool(forKey: Key.hasLaunchedBefore) {
                defaults.set(true, forKey: Key.hasLaunchedBefore)
                menuBar?.openSettings()
            }

        case .denied, .unavailable:
            menuBar?.needsPermission = true

            // The system prompt only ever appears once per app, so fire it on
            // the first run and rely on the setup window from then on.
            if !defaults.bool(forKey: Key.hasRequestedCapture) {
                defaults.set(true, forKey: Key.hasRequestedCapture)
                ScreenPermission.requestFromSystem()
            }
            // Deliberately not marking this as a completed first launch. The
            // user has not seen the app work yet, so the first launch that
            // actually has permission should still open Settings for them.
            menuBar?.openOnboarding()
        }
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Clamshell could not start"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
