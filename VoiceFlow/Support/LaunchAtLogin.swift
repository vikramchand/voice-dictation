import Foundation
import ServiceManagement

/// Login-item registration via `SMAppService`.
///
/// No helper bundle and no deprecated `LSSharedFileList`: the app registers itself,
/// which is what a menu bar utility wants.
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the error when registration fails so the caller can surface it.
    /// Failure is common and benign in debug builds — an unsigned app run from
    /// DerivedData can't be registered as a login item.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return nil
        } catch {
            return error
        }
    }
}
