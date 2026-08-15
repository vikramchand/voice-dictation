import SwiftUI

/// The settings window: General, Speech, LLM, Privacy.
struct SettingsView: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: DictationCoordinator

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gearshape") }

            SpeechSettingsTab(settings: settings)
                .tabItem { Label("Speech", systemImage: "waveform") }

            LLMSettingsTab(settings: settings, coordinator: coordinator)
                .tabItem { Label("LLM", systemImage: "brain") }

            PrivacyTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: DictationCoordinator

    var body: some View {
        Form {
            Section {
                StatusView(settings: settings, coordinator: coordinator)
            }

            Section {
                LabeledContent("Global hotkey") {
                    HotkeyRecorderView(shortcut: $settings.hotkey)
                }
                Text("Hold the hotkey while you speak, then release to insert the text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Mode", selection: $settings.mode) {
                    ForEach(DictationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Text(settings.mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Insert plain transcript if the LLM is unavailable",
                       isOn: $settings.insertRawTranscriptOnLLMFailure)
                Toggle("Type text instead of pasting", isOn: $settings.useDirectTyping)
                Text("Typing is slower but works in apps that block \u{2318}V, such as some "
                     + "terminals and secure fields.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Required for the global hotkey and for inserting text.",
                    isGranted: coordinator.hasAccessibilityPermission,
                    action: { coordinator.requestAccessibilityPermission() }
                )
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.hotkey) { _, _ in
            coordinator.refreshHotkey()
        }
        .onChange(of: settings.launchAtLogin) { _, newValue in
            LaunchAtLogin.setEnabled(newValue)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isGranted {
                Button("Grant\u{2026}", action: action)
            }
        }
    }
}

// MARK: - Speech

private struct SpeechSettingsTab: View {
    @ObservedObject var settings: AppSettings

    /// The models the download script produces, smallest first.
    private let knownModels = ["tiny", "base", "small", "medium", "large-v3-turbo"]

    var body: some View {
        Form {
            Section("Whisper model") {
                Picker("Model", selection: modelSelection) {
                    ForEach(knownModels, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    Text("Custom\u{2026}").tag("custom")
                }

                TextField("Model file", text: $settings.whisperModelPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

                HStack {
                    Image(systemName: modelExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(modelExists ? Color.green : Color.orange)
                    Text(modelExists ? "Model found" : "Model not found \u{2014} run scripts/download-whisper-model.sh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Language") {
                Picker("Language", selection: $settings.language) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Hindi").tag("hi")
                    Text("Japanese").tag("ja")
                    Text("Chinese").tag("zh")
                }
                Text("Naming the language is faster and more accurate than auto-detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("whisper.cpp binary") {
                TextField("Leave empty to auto-detect", text: $settings.whisperBinaryPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Text("Searched: /opt/homebrew/bin, /usr/local/bin, /opt/local/bin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var modelExists: Bool {
        FileManager.default.fileExists(atPath: settings.whisperModelPath)
    }

    /// Maps the picker onto the model *path*, falling back to "custom" when the path
    /// doesn't match the standard `ggml-<name>.bin` layout.
    private var modelSelection: Binding<String> {
        Binding(
            get: {
                let name = settings.whisperModelDisplayName
                return knownModels.contains(name) ? name : "custom"
            },
            set: { newValue in
                guard newValue != "custom" else { return }
                settings.whisperModelPath = AppPaths.modelsDirectory
                    .appendingPathComponent("ggml-\(newValue).bin").path
            }
        )
    }
}

// MARK: - LLM

private struct LLMSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: DictationCoordinator

    var body: some View {
        Form {
            Section("Provider") {
                LabeledContent("Provider", value: "Ollama (local)")

                TextField("Endpoint", text: $settings.llmEndpointString)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

                TextField("Model", text: $settings.llmModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

                Text("Install a model with `ollama pull \(settings.llmModel)`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Generation") {
                LabeledContent("Temperature") {
                    HStack {
                        Slider(value: $settings.temperature, in: 0...1, step: 0.05)
                        Text(String(format: "%.2f", settings.temperature))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Text("Low values keep the editor faithful to what was said.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(
                    "Max tokens: \(settings.maxTokens)",
                    value: $settings.maxTokens,
                    in: 128...8192,
                    step: 128
                )
            }

            Section("Status") {
                if let problem = coordinator.serviceStatus {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Whisper and Ollama are both reachable", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Button("Check now") {
                    Task { await coordinator.checkLocalServices() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Everything stays on this Mac", systemImage: "lock.shield.fill")
                    .font(.headline)

                Text("""
                All speech recognition and LLM processing happens locally on this Mac.

                VoiceFlow does not upload your recordings or transcripts.
                """)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    PrivacyPoint("Audio is held in memory and written to a temporary file only "
                                 + "for as long as Whisper needs to read it, then deleted.")
                    PrivacyPoint("Speech recognition runs in a local whisper.cpp process.")
                    PrivacyPoint("Cleanup runs against a local Ollama server. The only network "
                                 + "request VoiceFlow ever makes is to that endpoint.")
                    PrivacyPoint("No analytics, telemetry, crash reporting, remote logging, or accounts.")
                    PrivacyPoint("Transcripts are never written to disk or logged.")
                }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PrivacyPoint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.bold())
                .foregroundStyle(.green)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
