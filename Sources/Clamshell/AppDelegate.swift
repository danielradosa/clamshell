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

        NSApp.setActivationPolicy(.accessory)

        do {
            let controller = try FoldController()
            self.controller = controller
            self.menuBar = MenuBarController(controller: controller)
        } catch {
            presentFatal(error)
            return
        }

        Task {
            await establishCapturePermission()
            if CommandLine.arguments.contains("--demo") {
                controller?.playDemo()
            }
        }
    }

    private func establishCapturePermission() async {
        let defaults = UserDefaults.standard
        let state = await ScreenPermission.check()

        switch state {
        case .granted:
            controller?.isCaptureAllowed = true
            menuBar?.needsPermission = false
            if !defaults.bool(forKey: Key.hasLaunchedBefore) {
                defaults.set(true, forKey: Key.hasLaunchedBefore)
                menuBar?.openSettings()
            }

        case .denied, .unavailable:
            menuBar?.needsPermission = true

            if !defaults.bool(forKey: Key.hasRequestedCapture) {
                defaults.set(true, forKey: Key.hasRequestedCapture)
                ScreenPermission.requestFromSystem()
            }
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
