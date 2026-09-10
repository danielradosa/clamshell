import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: FoldController?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        if !ScreenCapture.hasPermission {
            requestScreenRecording()
        }
    }

    /// Screen Recording is the one permission the app cannot work without: the
    /// effect is a transformed copy of the desktop, so without capture there is
    /// nothing to fold.
    private func requestScreenRecording() {
        // Fire the system prompt first. macOS only ever shows it once per app,
        // so the explanation below has to cover the case where it never appears.
        ScreenCapture.requestPermission()

        let alert = NSAlert()
        alert.messageText = "Clamshell needs Screen Recording access"
        alert.informativeText = """
        The fold effect is a live copy of your desktop bent in 3D, so macOS \
        counts it as screen recording.

        Nothing is recorded, uploaded or written to disk. Frames go straight \
        from the capture stream to the GPU and are discarded.

        If no system prompt appeared, add Clamshell yourself under Privacy & \
        Security ▸ Screen & System Audio Recording, then relaunch.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
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
