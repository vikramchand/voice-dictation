import AppKit
import SwiftUI

/// Click, then press a shortcut to rebind the push-to-talk key.
///
/// Uses a local event monitor, which only sees events while VoiceFlow is frontmost —
/// exactly the case while the settings window is open, and it means recording a
/// shortcut can't swallow keystrokes meant for other apps.
struct HotkeyRecorderView: View {

    @Binding var shortcut: HotkeyShortcut
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(isRecording ? "Press a shortcut\u{2026}" : shortcut.displayName)
                .font(.system(.body, design: .rounded))
                .frame(minWidth: 120)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .help("Click, then hold the modifier and press the key you want to use.")
        .onDisappear(perform: stopRecording)
    }

    private func toggle() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Escape abandons the recording without changing the binding.
            if event.type == .keyDown, event.keyCode == 53 {
                stopRecording()
                return nil
            }

            guard event.type == .keyDown else { return event }

            let modifiers = HotkeyModifiers(nsFlags: event.modifierFlags)
            // A bare key would fire on every keystroke system-wide, so require at
            // least one modifier.
            guard !modifiers.isEmpty else { return nil }

            shortcut = HotkeyShortcut(keyCode: event.keyCode, modifiers: modifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}
