import AppKit
import SwiftUI
import ServiceManagement

/// The status item, its menu, and the settings window.
///
/// Built on NSStatusItem rather than SwiftUI's MenuBarExtra: an LSUIElement app
/// that also opens a real window is exactly the case where MenuBarExtra's window
/// handling is least predictable, and NSStatusItem gives direct control over
/// activation.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private weak var controller: FoldController?

    init(controller: FoldController?) {
        self.controller = controller
        super.init()
        installStatusItem()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "laptopcomputer", accessibilityDescription: "Clamshell"
            )
            button.image?.isTemplate = true
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let pause = NSMenuItem(
            title: "Pause", action: #selector(togglePause), keyEquivalent: ""
        )
        pause.target = self
        pause.tag = 1
        menu.addItem(pause)

        let demo = NSMenuItem(
            title: "Preview Effect", action: #selector(playDemo), keyEquivalent: ""
        )
        demo.target = self
        menu.addItem(demo)

        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(
            title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.tag = 2
        menu.addItem(launchAtLogin)

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: "About Clamshell", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Clamshell", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Actions

    @objc private func playDemo() {
        controller?.playDemo()
    }

    /// SMAppService registers the bundle by its path, so this only sticks for an
    /// app in a stable location. Running straight out of the build directory
    /// registers a path that will not survive a `make clean`.
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
                + "\n\nmacOS registers login items by bundle path. Install "
                + "Clamshell to /Applications and try again."
            alert.alertStyle = .warning
            NSApp.activate()
            alert.runModal()
        }
        refreshStatusAppearance()
    }

    @objc private func togglePause() {
        guard let controller else { return }
        controller.isPaused.toggle()
        refreshStatusAppearance()
    }

    private func refreshStatusAppearance() {
        let paused = controller?.isPaused ?? false
        statusItem?.button?.appearsDisabled = paused
        if let item = statusItem?.menu?.item(withTag: 1) {
            item.title = paused ? "Resume" : "Pause"
        }
        if let item = statusItem?.menu?.item(withTag: 2) {
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            bringToFront(window)
            return
        }

        let model = SettingsModel(controller: controller)
        settingsModel = model
        let hosting = NSHostingController(rootView: SettingsView(model: model))

        let window = NSWindow(contentViewController: hosting)
        window.title = "Clamshell"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        bringToFront(window)
    }

    /// An LSUIElement app is not in the activation order, so ordering a window
    /// front is not enough to give it focus. Activating the app first is what
    /// makes the window actually take key, and it must happen before the
    /// makeKeyAndOrderFront call rather than after.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Clamshell",
            .init(rawValue: "Copyright"): "MIT licensed. github.com/danielradosa/clamshell",
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        settingsModel?.endPreview()
        settingsModel = nil
        settingsWindow = nil
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusAppearance()
    }
}
