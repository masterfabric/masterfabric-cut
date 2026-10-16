import AppKit

/// Single integration point between the app shell and feature modules.
/// Menu items and global hotkeys both route through `perform(_:)`.
final class AppCoordinator {
    static let shared = AppCoordinator()

    func perform(_ action: ShortcutAction) {
        switch action {
        case .toggleDesktopIcons:
            DesktopIcons.setHidden(!AppSettings.shared.hideDesktopIcons)
        default:
            NSLog("Action not yet wired: \(action.title)")
        }
    }
}
