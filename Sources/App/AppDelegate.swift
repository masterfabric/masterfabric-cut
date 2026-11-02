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
        #if DEBUG
        // Dev/screenshot hook: MFC_DEMO_QR=<link> opens the QR tool prefilled; MFC_DEMO_QR_PRESENT=1 also presents it.
        let env = ProcessInfo.processInfo.environment
        if let link = env["MFC_DEMO_QR"] {
            let tool = QRCodeToolWindowController.shared
            tool.model.input = link; tool.model.generate(); tool.show()
            if env["MFC_DEMO_QR_PRESENT"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tool.model.present() } }
            // MFC_DEMO_SNAPSHOT_DIR=<dir>: write PNG snapshots of the tool and presentation windows (no Screen Recording needed).
            if let dir = env["MFC_DEMO_SNAPSHOT_DIR"] {
                func snap(_ w: NSWindow?, _ name: String) {
                    guard let v = w?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    snap(NSApp.windows.first { $0.title == "Link to QR Code" }, "qr-tool.png")
                    tool.model.present()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        snap(NSApp.windows.first { $0.level == .statusBar && $0.styleMask == [.borderless] && $0.frame.width > 400 }, "qr-present.png")
                    }
                }
            }
        }
        #endif
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image(recording: false)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        // The dropdown is a custom SwiftUI panel (MenuBarPanel.swift); it observes state itself.
        statusItem?.button?.image = MenuBarIcon.image(recording: AppCoordinator.shared.recorder.state.isActive)
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
            w.isReleasedWhenClosed = false; w.title = "Settings"; w.styleMask = [.titled, .closable, .fullSizeContentView]; w.titlebarAppearsTransparent = true
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
