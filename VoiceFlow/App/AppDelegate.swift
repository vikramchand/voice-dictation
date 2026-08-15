import AppKit
import Foundation

/// Wires the object graph together and owns it for the process lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = AppSettings()
    private lazy var coordinator = DictationCoordinator(settings: settings)
    private lazy var settingsWindow = SettingsWindowController(
        settings: settings,
        coordinator: coordinator
    )
    private lazy var menuBar = MenuBarController(
        settings: settings,
        coordinator: coordinator,
        openSettings: { [weak self] in self?.settingsWindow.show() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()
        cleanUpStaleRecordings()

        menuBar.install()
        coordinator.start()

        // Ask for the microphone up front rather than on the first recording. The
        // permission dialog would otherwise appear while the user is already holding
        // the hotkey and talking, and the start of the utterance would be lost.
        Task { try? await AudioRecorder.ensureMicrophoneAccess() }

        // Accessibility gates both the hotkey and pasting, so ask on first run and
        // open settings so the user can see why nothing is working yet.
        if !GlobalHotkeyManager.hasAccessibilityPermission {
            GlobalHotkeyManager.requestAccessibilityPermission()
            settingsWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        cleanUpStaleRecordings()
    }

    /// A crash mid-dictation can leave a WAV behind. Clear the directory at both
    /// ends of the process lifetime so recordings never accumulate.
    private func cleanUpStaleRecordings() {
        let directory = AppPaths.recordingsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in contents where url.pathExtension == "wav" || url.pathExtension == "txt" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
