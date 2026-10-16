import ServiceManagement

enum LaunchAtLogin {
    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            AppSettings.shared.launchAtLogin = enabled
        } catch { NSLog("LaunchAtLogin: \(error)") }
    }
}
