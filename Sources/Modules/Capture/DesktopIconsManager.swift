// MasterFabric Cut — Capture module
// Author: Gürkan Fikret Günak · masterfabric.co
import Foundation

/// Hides/shows Finder desktop icons (Finder's `CreateDesktop` default). Requires a non-sandboxed app.
public enum DesktopIconsManager {
    public static var iconsHidden: Bool {
        let out = run("/usr/bin/defaults", ["read", "com.apple.finder", "CreateDesktop"])
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "0" || v == "false" || v == "no"
    }

    public static func setIconsHidden(_ hidden: Bool) {
        _ = run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
        _ = run("/usr/bin/killall", ["Finder"])
    }

    public static func toggle() { setIconsHidden(!iconsHidden) }

    /// Hide icons, run `body`, restore the previous state. Waits for Finder to redraw.
    public static func withIconsHidden<T>(_ body: () async throws -> T) async rethrows -> T {
        let was = iconsHidden
        if !was { setIconsHidden(true); try? await Task.sleep(nanoseconds: 900_000_000) }
        defer { if !was { setIconsHidden(false) } }
        return try await body()
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
