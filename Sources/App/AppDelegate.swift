import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var prefsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        NotificationCenter.default.addObserver(forName: ShortcutStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "MasterFabric Cut")
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        func add(_ a: ShortcutAction, _ symbol: String) {
            let i = NSMenuItem(title: a.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            i.representedObject = a.rawValue
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let c = ShortcutStore.shared.combo(for: a) { i.title += "    " + c.displayString }
            i.target = self
            menu.addItem(i)
        }
        add(.captureArea, "rectangle.dashed")
        add(.captureWindow, "macwindow")
        add(.captureFullscreen, "display")
        add(.capturePreviousArea, "arrow.counterclockwise")
        add(.scrollingCapture, "arrow.up.and.down.text.horizontal")
        add(.captureText, "text.viewfinder")
        add(.selfTimer, "timer")
        menu.addItem(.separator())
        add(.recordScreen, "record.circle")
        add(.recordGIF, "gift")
        add(.recordingStudio, "video.badge.waveform")
        menu.addItem(.separator())
        add(.toggleDesktopIcons, "eye.slash")
        add(.openHistory, "clock.arrow.circlepath")
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = self; menu.addItem(prefs)
        let about = NSMenuItem(title: "About MasterFabric Cut", action: #selector(showAbout), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = ShortcutAction(rawValue: raw) else { return }
        AppCoordinator.shared.perform(a)
    }

    // MARK: Windows

    @objc func showPreferences() {
        if prefsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView()))
            w.title = "MasterFabric Cut Preferences"; w.styleMask = [.titled, .closable]
            prefsWindow = w
        }
        present(prefsWindow!)
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            w.title = "About MasterFabric Cut"; w.styleMask = [.titled, .closable]
            aboutWindow = w
        }
        present(aboutWindow!)
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.center(); w.makeKeyAndOrderFront(nil)
    }
}
