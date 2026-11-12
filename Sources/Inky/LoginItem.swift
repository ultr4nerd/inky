import Foundation
import ServiceManagement

/// Open Inky at login (SMAppService, macOS 13+). Turned on automatically the first time
/// Inky runs from an Applications folder; toggle in Settings.
enum LoginItem {
    private static let setUpKey = "loginItemSetUp"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.info("login item \(on ? "on" : "off")")
        } catch {
            Log.info("login item failed: \(error.localizedDescription)")
        }
    }

    static func setUpIfInstalled() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: setUpKey) else { return }
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else { return }
        set(true)
        d.set(true, forKey: setUpKey)
    }
}
