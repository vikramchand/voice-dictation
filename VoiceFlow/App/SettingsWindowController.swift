import AppKit
import SwiftUI

/// Owns the settings window.
///
/// A plain `NSWindowController` hosting the SwiftUI view rather than SwiftUI's
/// `Settings` scene, because an accessory app needs to activate itself explicitly
/// before showing a window, and the window has to be reusable across openings.
@MainActor
final class SettingsWindowController {

    private var window: NSWindow?
    private let settings: AppSettings
    private let coordinator: DictationCoordinator

    init(settings: AppSettings, coordinator: DictationCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        guard let window else { return }

        // An `.accessory` app is not in the Dock and doesn't activate on its own,
        // so the window would otherwise open behind whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsView(settings: settings, coordinator: coordinator)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "VoiceFlow Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false   // reopened on the next Settings… click
        window.setContentSize(NSSize(width: 520, height: 420))
        return window
    }
}
