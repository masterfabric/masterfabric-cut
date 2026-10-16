import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var prefsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        AppCoordinator.shared.start()
        AppCoordinator.shared.onRecordingStateChange = { [weak self] in self?.rebuildMenu() }
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
        let rec = AppCoordinator.shared.recorder
        if rec.state.isActive {
            let stop = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            stop.target = self; menu.addItem(stop)
            let pause = NSMenuItem(title: rec.state == .paused ? "Resume Recording" : "Pause Recording",
                                   action: #selector(pauseRecording), keyEquivalent: "")
            pause.target = self; menu.addItem(pause)
            menu.addItem(.separator())
        }
        func add(_ a: CaptureAction, _ symbol: String) {
            let i = NSMenuItem(title: a.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            i.representedObject = a.rawValue
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let c = HotkeyManager.shared.bindings[a] { i.title += "    " + c.displayString }
            i.target = self
            menu.addItem(i)
        }
        add(.captureArea, "rectangle.dashed")
        add(.captureWindow, "macwindow")
        add(.captureFullscreen, "display")
        add(.capturePreviousArea, "arrow.counterclockwise")
        add(.captureScrolling, "arrow.up.and.down.text.horizontal")
        add(.captureText, "text.viewfinder")
        let timer = NSMenuItem(title: "Self-Timer Capture", action: #selector(selfTimer), keyEquivalent: "")
        timer.target = self; timer.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil); menu.addItem(timer)
        menu.addItem(.separator())
        add(.recordScreen, "record.circle")
        add(.recordGIF, "gift")
        add(.openStudio, "video.badge.waveform")
        menu.addItem(.separator())
        add(.toggleDesktopIcons, "eye.slash")
        let pin = NSMenuItem(title: "Pin Clipboard Image", action: #selector(pinClipboard), keyEquivalent: "")
        pin.target = self; pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil); menu.addItem(pin)
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
        guard let raw = sender.representedObject as? String, let a = CaptureAction(rawValue: raw) else { return }
        // Let the menu close before capture overlays appear.
        DispatchQueue.main.async { AppCoordinator.shared.perform(a) }
    }
    @objc private func selfTimer() { DispatchQueue.main.async { AppCoordinator.shared.selfTimerCapture() } }
    @objc private func stopRecording() { AppCoordinator.shared.stopRecording() }
    @objc private func pauseRecording() { AppCoordinator.shared.togglePauseRecording() }
    @objc private func pinClipboard() { AppCoordinator.shared.pinClipboardImage() }

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
