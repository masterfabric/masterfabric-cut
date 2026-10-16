// MasterFabric Cut — Shared/Storage
// Author: Gürkan Fikret Günak · masterfabric.co
import Foundation
import SQLite3

/// Key/value preferences and app state persisted in SQLite. API mirrors the subset of `UserDefaults` the app uses,
/// so settings code stays unchanged. Values are cached in memory; writes go straight to the DB.
final class AppStateStore {
    static let shared = AppStateStore()

    private let db = Database.shared
    private var cache: [String: String] = [:]
    private var defaults: [String: String] = [:]
    private let lock = NSLock()

    private init() {
        db.run("SELECT key, value FROM kv") { [self] s in
            if let k = Database.text(s, 0), let v = Database.text(s, 1) { cache[k] = v }
        }
        importUserDefaultsIfNeeded()
    }

    // MARK: Defaults

    func register(defaults d: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        for (k, v) in d { defaults[k] = Self.encode(v) }
    }

    // MARK: Reads

    private func raw(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[key] ?? defaults[key]
    }
    func bool(forKey k: String) -> Bool { raw(k).map { $0 == "1" || $0 == "true" } ?? false }
    func integer(forKey k: String) -> Int { raw(k).flatMap { Int($0) ?? Double($0).map(Int.init) } ?? 0 }
    func double(forKey k: String) -> Double { raw(k).flatMap(Double.init) ?? 0 }
    func string(forKey k: String) -> String? { raw(k) }
    func data(forKey k: String) -> Data? { raw(k).flatMap { Data(base64Encoded: $0) } }

    // MARK: Writes

    func set(_ value: Any?, forKey k: String) {
        guard let value else { removeObject(forKey: k); return }
        let s = Self.encode(value)
        lock.lock(); cache[k] = s; lock.unlock()
        db.run("INSERT INTO kv(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
               [.text(k), .text(s)])
    }

    func removeObject(forKey k: String) {
        lock.lock(); cache[k] = nil; lock.unlock()
        db.run("DELETE FROM kv WHERE key = ?1", [.text(k)])
    }

    private static func encode(_ v: Any) -> String {
        switch v {
        case let b as Bool: return b ? "1" : "0"
        case let d as Data: return d.base64EncodedString()
        default: return "\(v)"
        }
    }

    // MARK: Migration from UserDefaults

    private static let legacyKeys = [
        "launchAtLogin", "playSounds", "showMenuBarIcon", "freezeScreen", "showMagnifier", "showCrosshair",
        "imageFormat", "jpegQuality", "retina", "copyToClipboard", "saveAutomatically", "windowShadow", "timerSeconds",
        "overlayEnabled", "overlayCorner", "overlayAutoCloseSeconds", "overlayCloseAfterAction",
        "recordFPS", "gifFPS", "recordMic", "recordSystemAudio", "showClicks", "showKeystrokes", "hideDesktopIcons",
        "historyLimit", "onboardingCompleted", "showLauncher", "filenameTemplate", "saveDirectory", "launcherOrigin",
        "com.masterfabric.cut.hotkeys", "com.masterfabric.cut.previousArea",
    ]

    /// One-time copy of existing UserDefaults values (preferences, onboarding flag, hotkeys, previous area) into the DB.
    private func importUserDefaultsIfNeeded() {
        guard cache["migrated.userdefaults"] == nil else { return }
        let ud = UserDefaults.standard
        for k in Self.legacyKeys {
            guard let v = ud.object(forKey: k) else { continue }
            set(v, forKey: k)
        }
        // Permission "already asked" flags written by earlier PermissionManager builds.
        for p in Permission.allCases where ud.bool(forKey: "perm.requested.\(p.rawValue)") {
            PermissionStore.shared.markRequested(p.rawValue)
        }
        set(true, forKey: "migrated.userdefaults")
    }
}

/// Per-permission "already requested" flag and last known status, persisted in SQLite.
final class PermissionStore {
    static let shared = PermissionStore()
    private let db = Database.shared

    func wasRequested(_ name: String) -> Bool {
        var result = false
        db.run("SELECT requested FROM permissions WHERE name = ?1", [.text(name)]) { s in
            result = sqlite3_column_int(s, 0) != 0
        }
        return result
    }

    func markRequested(_ name: String) {
        db.run("""
            INSERT INTO permissions(name, requested, updated_at) VALUES(?1, 1, ?2)
            ON CONFLICT(name) DO UPDATE SET requested = 1, updated_at = excluded.updated_at
            """, [.text(name), .double(Date().timeIntervalSince1970)])
    }

    func lastStatus(_ name: String) -> String? {
        var result: String?
        db.run("SELECT last_status FROM permissions WHERE name = ?1", [.text(name)]) { s in result = Database.text(s, 0) }
        return result
    }

    func saveStatus(_ name: String, _ status: String) {
        db.run("""
            INSERT INTO permissions(name, last_status, updated_at) VALUES(?1, ?2, ?3)
            ON CONFLICT(name) DO UPDATE SET last_status = excluded.last_status, updated_at = excluded.updated_at
            """, [.text(name), .text(status), .double(Date().timeIntervalSince1970)])
    }
}
