import Foundation
import AppKit
import Combine

/// Image format used when saving screenshots.
enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpg, tiff
    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var displayName: String { rawValue.uppercased() }
}

/// Where Quick Access Overlay is anchored on screen.
enum OverlayCorner: String, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        }
    }
}

/// Central, SQLite-backed (AppStateStore) preferences shared across modules.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = AppStateStore.shared

    private init() {
        d.register(defaults: [
            "launchAtLogin": false, "playSounds": true, "showMenuBarIcon": true,
            "freezeScreen": false, "showMagnifier": true, "showCrosshair": true,
            "imageFormat": ImageFormat.png.rawValue, "jpegQuality": 0.9,
            "retina": true, "copyToClipboard": false, "saveAutomatically": true,
            "windowShadow": true, "timerSeconds": 5,
            "overlayEnabled": true, "overlayCorner": OverlayCorner.bottomLeft.rawValue,
            "overlayAutoCloseSeconds": 6, "overlayCloseAfterAction": true,
            "recordFPS": 30, "gifFPS": 15, "recordMic": false, "recordSystemAudio": true,
            "showClicks": true, "showKeystrokes": false, "hideDesktopIcons": false,
            "historyLimit": 200, "studioCountdown": 3, "studioMirror": true, "studioShape": "circle", "onboardingCompleted": false, "showLauncher": true, "filenameTemplate": "MasterFabric Cut %Y-%m-%d at %H.%M.%S",
            "saveDirectory": NSString(string: "~/Desktop").expandingTildeInPath,
        ])
    }

    private func set<T>(_ v: T, _ k: String) { objectWillChange.send(); d.set(v, forKey: k) }

    var launchAtLogin: Bool { get { d.bool(forKey: "launchAtLogin") } set { set(newValue, "launchAtLogin") } }
    var playSounds: Bool { get { d.bool(forKey: "playSounds") } set { set(newValue, "playSounds") } }
    var showMenuBarIcon: Bool { get { d.bool(forKey: "showMenuBarIcon") } set { set(newValue, "showMenuBarIcon") } }
    var freezeScreen: Bool { get { d.bool(forKey: "freezeScreen") } set { set(newValue, "freezeScreen") } }
    var showMagnifier: Bool { get { d.bool(forKey: "showMagnifier") } set { set(newValue, "showMagnifier") } }
    var showCrosshair: Bool { get { d.bool(forKey: "showCrosshair") } set { set(newValue, "showCrosshair") } }
    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png }
        set { set(newValue.rawValue, "imageFormat") }
    }
    var jpegQuality: Double { get { d.double(forKey: "jpegQuality") } set { set(newValue, "jpegQuality") } }
    var retina: Bool { get { d.bool(forKey: "retina") } set { set(newValue, "retina") } }
    var copyToClipboard: Bool { get { d.bool(forKey: "copyToClipboard") } set { set(newValue, "copyToClipboard") } }
    var saveAutomatically: Bool { get { d.bool(forKey: "saveAutomatically") } set { set(newValue, "saveAutomatically") } }
    var windowShadow: Bool { get { d.bool(forKey: "windowShadow") } set { set(newValue, "windowShadow") } }
    var timerSeconds: Int { get { d.integer(forKey: "timerSeconds") } set { set(newValue, "timerSeconds") } }
    var overlayEnabled: Bool { get { d.bool(forKey: "overlayEnabled") } set { set(newValue, "overlayEnabled") } }
    var overlayCorner: OverlayCorner {
        get { OverlayCorner(rawValue: d.string(forKey: "overlayCorner") ?? "") ?? .bottomLeft }
        set { set(newValue.rawValue, "overlayCorner") }
    }
    var overlayAutoCloseSeconds: Int { get { d.integer(forKey: "overlayAutoCloseSeconds") } set { set(newValue, "overlayAutoCloseSeconds") } }
    var overlayCloseAfterAction: Bool { get { d.bool(forKey: "overlayCloseAfterAction") } set { set(newValue, "overlayCloseAfterAction") } }
    var recordFPS: Int { get { d.integer(forKey: "recordFPS") } set { set(newValue, "recordFPS") } }
    var gifFPS: Int { get { d.integer(forKey: "gifFPS") } set { set(newValue, "gifFPS") } }
    var recordMic: Bool { get { d.bool(forKey: "recordMic") } set { set(newValue, "recordMic") } }
    var recordSystemAudio: Bool { get { d.bool(forKey: "recordSystemAudio") } set { set(newValue, "recordSystemAudio") } }
    var showClicks: Bool { get { d.bool(forKey: "showClicks") } set { set(newValue, "showClicks") } }
    var showKeystrokes: Bool { get { d.bool(forKey: "showKeystrokes") } set { set(newValue, "showKeystrokes") } }
    var hideDesktopIcons: Bool { get { d.bool(forKey: "hideDesktopIcons") } set { set(newValue, "hideDesktopIcons") } }
    var onboardingCompleted: Bool { get { d.bool(forKey: "onboardingCompleted") } set { set(newValue, "onboardingCompleted") } }
    var showLauncher: Bool { get { d.bool(forKey: "showLauncher") } set { set(newValue, "showLauncher") } }
    var launcherOrigin: CGPoint? {
        get { d.string(forKey: "launcherOrigin").map { NSPointFromString($0) } }
        set { d.set(newValue.map { NSStringFromPoint($0) }, forKey: "launcherOrigin") }
    }
    var studioCountdown: Int { get { d.integer(forKey: "studioCountdown") } set { set(newValue, "studioCountdown") } }
    var studioMirror: Bool { get { d.bool(forKey: "studioMirror") } set { set(newValue, "studioMirror") } }
    var studioShape: String { get { d.string(forKey: "studioShape") ?? "circle" } set { set(newValue, "studioShape") } }
    var historyLimit: Int { get { d.integer(forKey: "historyLimit") } set { set(newValue, "historyLimit") } }
    var filenameTemplate: String { get { d.string(forKey: "filenameTemplate") ?? "" } set { set(newValue, "filenameTemplate") } }
    var saveDirectory: URL {
        get { URL(fileURLWithPath: d.string(forKey: "saveDirectory") ?? NSHomeDirectory()) }
        set { set(newValue.path, "saveDirectory") }
    }

    /// Expands the filename template (strftime-style tokens) for "now".
    func makeFilename(ext: String, date: Date = Date()) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var tmv = tm(); localtime_r(&t, &tmv)
        var buf = [Int8](repeating: 0, count: 256)
        strftime(&buf, buf.count, filenameTemplate, &tmv)
        return String(cString: buf) + "." + ext
    }
}
