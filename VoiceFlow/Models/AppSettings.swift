import Foundation

/// The slice of `UserDefaults` that `AppSettings` needs, so tests can inject a
/// throwaway store instead of polluting the real domain.
protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// User-visible preferences, persisted immediately on change.
///
/// Deliberately not `@MainActor`: SwiftUI drives it from the main thread, and the
/// pipeline never touches it directly — it gets a `PipelineConfiguration` snapshot.
final class AppSettings: ObservableObject {

    private enum Key {
        static let mode = "mode"
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let launchAtLogin = "launchAtLogin"

        static let whisperBinaryPath = "speech.binaryPath"
        static let whisperModelPath = "speech.modelPath"
        static let language = "speech.language"

        static let llmProvider = "llm.provider"
        static let llmModel = "llm.model"
        static let llmEndpoint = "llm.endpoint"
        static let llmTemperature = "llm.temperature"
        static let llmMaxTokens = "llm.maxTokens"

        static let insertRawOnLLMFailure = "behavior.insertRawOnLLMFailure"
        static let useDirectTyping = "behavior.useDirectTyping"
    }

    private let store: any KeyValueStore

    // MARK: - General

    @Published var mode: DictationMode {
        didSet { store.set(mode.rawValue, forKey: Key.mode) }
    }

    @Published var hotkey: HotkeyShortcut {
        didSet {
            store.set(Int(hotkey.keyCode), forKey: Key.hotkeyKeyCode)
            store.set(hotkey.modifiers.rawValue, forKey: Key.hotkeyModifiers)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet { store.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    // MARK: - Speech

    /// Empty string means "auto-discover".
    @Published var whisperBinaryPath: String {
        didSet { store.set(whisperBinaryPath, forKey: Key.whisperBinaryPath) }
    }

    @Published var whisperModelPath: String {
        didSet { store.set(whisperModelPath, forKey: Key.whisperModelPath) }
    }

    @Published var language: String {
        didSet { store.set(language, forKey: Key.language) }
    }

    // MARK: - LLM

    @Published var llmProvider: String {
        didSet { store.set(llmProvider, forKey: Key.llmProvider) }
    }

    @Published var llmModel: String {
        didSet { store.set(llmModel, forKey: Key.llmModel) }
    }

    @Published var llmEndpointString: String {
        didSet { store.set(llmEndpointString, forKey: Key.llmEndpoint) }
    }

    @Published var temperature: Double {
        didSet { store.set(temperature, forKey: Key.llmTemperature) }
    }

    @Published var maxTokens: Int {
        didSet { store.set(maxTokens, forKey: Key.llmMaxTokens) }
    }

    // MARK: - Behavior

    @Published var insertRawTranscriptOnLLMFailure: Bool {
        didSet { store.set(insertRawTranscriptOnLLMFailure, forKey: Key.insertRawOnLLMFailure) }
    }

    @Published var useDirectTyping: Bool {
        didSet { store.set(useDirectTyping, forKey: Key.useDirectTyping) }
    }

    // MARK: - Init

    init(store: any KeyValueStore = UserDefaults.standard) {
        self.store = store

        let defaults = PipelineConfiguration(
            mode: .dictate,
            speech: .default,
            llm: .default,
            insertRawTranscriptOnLLMFailure: true,
            useDirectTyping: false
        )

        mode = (store.object(forKey: Key.mode) as? String).flatMap(DictationMode.init(rawValue:)) ?? defaults.mode

        if let code = store.object(forKey: Key.hotkeyKeyCode) as? Int,
           let mods = store.object(forKey: Key.hotkeyModifiers) as? Int {
            hotkey = HotkeyShortcut(keyCode: UInt16(code), modifiers: HotkeyModifiers(rawValue: mods))
        } else {
            hotkey = .optionSpace
        }

        launchAtLogin = store.object(forKey: Key.launchAtLogin) as? Bool ?? false

        whisperBinaryPath = store.object(forKey: Key.whisperBinaryPath) as? String ?? ""
        whisperModelPath = store.object(forKey: Key.whisperModelPath) as? String ?? defaults.speech.modelPath
        language = store.object(forKey: Key.language) as? String ?? defaults.speech.language

        llmProvider = store.object(forKey: Key.llmProvider) as? String ?? defaults.llm.provider
        llmModel = store.object(forKey: Key.llmModel) as? String ?? defaults.llm.model
        llmEndpointString = store.object(forKey: Key.llmEndpoint) as? String ?? defaults.llm.endpoint.absoluteString
        temperature = store.object(forKey: Key.llmTemperature) as? Double ?? defaults.llm.temperature
        maxTokens = store.object(forKey: Key.llmMaxTokens) as? Int ?? defaults.llm.maxTokens

        insertRawTranscriptOnLLMFailure =
            store.object(forKey: Key.insertRawOnLLMFailure) as? Bool ?? defaults.insertRawTranscriptOnLLMFailure
        useDirectTyping = store.object(forKey: Key.useDirectTyping) as? Bool ?? defaults.useDirectTyping
    }

    // MARK: - Snapshot

    /// Falls back to the default endpoint if the user typed something unparsable,
    /// so a bad character in the settings field can't break dictation entirely.
    var llmEndpoint: URL {
        URL(string: llmEndpointString.trimmingCharacters(in: .whitespaces)) ?? LLMSettings.default.endpoint
    }

    func snapshot() -> PipelineConfiguration {
        let trimmedBinary = whisperBinaryPath.trimmingCharacters(in: .whitespaces)
        return PipelineConfiguration(
            mode: mode,
            speech: SpeechSettings(
                binaryPath: trimmedBinary.isEmpty ? nil : trimmedBinary,
                modelPath: whisperModelPath,
                language: language
            ),
            llm: LLMSettings(
                provider: llmProvider,
                model: llmModel,
                endpoint: llmEndpoint,
                temperature: temperature,
                maxTokens: maxTokens
            ),
            insertRawTranscriptOnLLMFailure: insertRawTranscriptOnLLMFailure,
            useDirectTyping: useDirectTyping
        )
    }

    /// Name shown in the menu, e.g. "small" for `ggml-small.bin`.
    var whisperModelDisplayName: String {
        let name = (whisperModelPath as NSString).lastPathComponent
        return name
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: ".bin", with: "")
    }
}
