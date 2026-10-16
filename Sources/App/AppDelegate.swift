import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var prefsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private let panel = MenuBarPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        AppCoordinator.shared.start()
        FloatingLauncher.shared.refresh()
        if !AppSettings.shared.onboardingCompleted { OnboardingWindow.shared.show() }
        AppCoordinator.shared.onRecordingStateChange = { [weak self] in self?.rebuildMenu() }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "MasterFabric Cut")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        // The dropdown is a custom SwiftUI panel (MenuBarPanel.swift); it observes state itself.
        statusItem?.button?.image = NSImage(systemSymbolName: AppCoordinator.shared.recorder.state.isActive ? "record.circle.fill" : "scissors",
                                            accessibilityDescription: "MasterFabric Cut")
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        var acts = MenuBarActions()
        acts.perform = { AppCoordinator.shared.perform($0) }
        acts.selfTimer = { AppCoordinator.shared.selfTimerCapture() }
        acts.pinClipboard = { AppCoordinator.shared.pinClipboardImage() }
        acts.preferences = { [weak self] in self?.showPreferences() }
        acts.welcome = { OnboardingWindow.shared.show() }
        acts.about = { [weak self] in self?.showAbout() }
        acts.openItem = { item in
            if let url = item.fileURL { NSWorkspace.shared.open(url) } else { AnnotateModule.shared.showHistory() }
        }
        panel.toggle(relativeTo: button, actions: acts)
    }

    // MARK: Windows

    @objc func showPreferences() {
        if prefsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView()))
            w.isReleasedWhenClosed = false; w.title = "MasterFabric Cut Preferences"; w.styleMask = [.titled, .closable]
            prefsWindow = w
        }
        present(prefsWindow!)
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            w.isReleasedWhenClosed = false; w.title = "About MasterFabric Cut"; w.styleMask = [.titled, .closable]
            aboutWindow = w
        }
        present(aboutWindow!)
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.center(); w.makeKeyAndOrderFront(nil)
    }
}
