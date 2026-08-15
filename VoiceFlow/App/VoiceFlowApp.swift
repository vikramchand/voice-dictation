import AppKit

/// Process entry point.
///
/// Uses an explicit `NSApplication` run loop rather than the SwiftUI `App` lifecycle:
/// VoiceFlow has no main window, and `.accessory` activation policy plus an
/// AppKit-owned status item is more predictable than driving `MenuBarExtra` and a
/// `Settings` scene from an agent app. SwiftUI is still used for every view.
@main
enum VoiceFlowApp {

    /// `NSApplication.delegate` is weak, so the delegate is parked here for the
    /// lifetime of the process.
    @MainActor private static var retainedDelegate: AppDelegate?

    @MainActor
    static func main() {
        let application = NSApplication.shared
        // No Dock icon and no app menu — this lives in the status bar.
        application.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate

        application.run()
    }
}
