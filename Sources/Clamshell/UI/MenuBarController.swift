import AppKit
import SwiftUI

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
    private var escapeMonitor: Any?

    init(controller: FoldController?) {
        self.controller = controller
        super.init()
        installStatusItem()
        installEscapeMonitor()
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

        menu.addItem(.separator())

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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Clamshell",
            .init(rawValue: "Copyright"): "MIT licensed. github.com/danielradosa/clamshell",
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Escape to pause

    /// A *local* monitor sees events only while this app is frontmost, which
    /// needs no Accessibility permission. A global monitor would catch Escape
    /// anywhere but would require the user to grant Accessibility access, which
    /// is a steep ask for a cosmetic feature.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // 53 = Escape
            self?.togglePause()
            return nil
        }
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
