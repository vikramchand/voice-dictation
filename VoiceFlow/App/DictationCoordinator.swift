import AppKit
import Foundation

/// Owns the hotkey → record → transcribe → clean → insert flow.
///
/// Main-actor because it drives UI. Everything expensive happens inside the actors
/// it calls (`AudioRecorder`, `TranscriptionPipeline`), so the main thread only ever
/// does state updates.
@MainActor
final class DictationCoordinator: ObservableObject {

    @Published private(set) var state: DictationState = .idle
    /// Result of the last local-services check, shown in the menu.
    @Published private(set) var serviceStatus: String?

    private let settings: AppSettings
    private let recorder: AudioRecorder
    private let hotkeys: GlobalHotkeyManager
    private let indicator: RecordingIndicatorController
    private let applicationProvider: any FrontmostApplicationProviding

    /// Captured at key-down, before any VoiceFlow UI appears, so it reflects the app
    /// the user was actually typing into.
    private var pendingContext: ApplicationContext = .unknown
    private var processingTask: Task<Void, Never>?

    /// Overridable so tests and future backends can substitute implementations.
    var makeRecognizer: (SpeechSettings) -> any SpeechRecognizer = { WhisperCppRecognizer(settings: $0) }
    var makeLLM: (LLMSettings) -> any LLMProvider = { OllamaProvider(settings: $0) }
    var makeInserter: (PipelineConfiguration) -> any TextInserting = {
        TextInsertionManager(useDirectTyping: $0.useDirectTyping)
    }

    init(
        settings: AppSettings,
        recorder: AudioRecorder = AudioRecorder(),
        // Not a default argument: `RecordingIndicatorController` is main-actor
        // isolated, and default-argument expressions are evaluated without isolation.
        indicator: RecordingIndicatorController? = nil,
        applicationProvider: any FrontmostApplicationProviding = WorkspaceApplicationProvider()
    ) {
        let indicator = indicator ?? RecordingIndicatorController()
        self.settings = settings
        self.recorder = recorder
        self.indicator = indicator
        self.applicationProvider = applicationProvider
        self.hotkeys = GlobalHotkeyManager(shortcut: settings.hotkey)

        indicator.levelSource = recorder.levelSource

        hotkeys.onBeginRecording = { [weak self] in self?.beginRecording() }
        hotkeys.onEndRecording = { [weak self] in self?.endRecording() }
    }

    // MARK: - Lifecycle

    func start() {
        AppPaths.ensureDirectories()
        startHotkeys()
        Task { await checkLocalServices() }
    }

    func stop() {
        hotkeys.stop()
        processingTask?.cancel()
    }

    private func startHotkeys() {
        do {
            try hotkeys.start()
        } catch {
            // Without the tap there is no hotkey at all, so say so loudly.
            setState(.failed(.accessibilityPermissionDenied))
        }
    }

    /// Re-reads the shortcut from settings and restarts the tap if it wasn't running
    /// (which is the normal case right after the user grants Accessibility).
    func refreshHotkey() {
        hotkeys.updateShortcut(settings.hotkey)
        if !hotkeys.isRunning {
            startHotkeys()
        }
    }

    var hasAccessibilityPermission: Bool {
        GlobalHotkeyManager.hasAccessibilityPermission
    }

    func requestAccessibilityPermission() {
        GlobalHotkeyManager.requestAccessibilityPermission()
    }

    // MARK: - Recording

    private func beginRecording() {
        guard !state.isBusy else { return }

        // Capture the target before the indicator appears.
        pendingContext = applicationProvider.currentContext()

        setState(.recording)
        // Inherits the main actor, so the failure handling below needs no hop back.
        Task { [recorder] in
            do {
                try await recorder.start()
            } catch let error as VoiceFlowError {
                self.fail(error)
            } catch {
                self.fail(.audioEngineFailed(error.localizedDescription))
            }
        }
    }

    private func endRecording() {
        guard case .recording = state else { return }

        setState(.processing(.transcribing))
        let configuration = settings.snapshot()
        let context = pendingContext

        processingTask = Task { [recorder, weak self] in
            do {
                let captured = try await recorder.stop()
                try await self?.process(
                    captured: captured,
                    context: context,
                    configuration: configuration
                )
            } catch let error as VoiceFlowError {
                self?.fail(error)
            } catch is CancellationError {
                self?.setState(.idle)
            } catch {
                self?.fail(.whisperFailed(error.localizedDescription))
            }
        }
    }

    private func process(
        captured: CapturedAudio,
        context: ApplicationContext,
        configuration: PipelineConfiguration
    ) async throws {
        let pipeline = TranscriptionPipeline(
            recognizer: makeRecognizer(configuration.speech),
            llm: makeLLM(configuration.llm),
            inserter: makeInserter(configuration),
            configuration: configuration
        )

        let result = try await pipeline.run(
            audioURL: captured.url,
            context: context,
            audioDuration: captured.duration
        ) { stage in
            Task { @MainActor [weak self] in
                self?.setState(.processing(stage))
            }
        }

        guard let result else {
            // Nothing was said. Drop back to idle without a "Done" flash.
            setState(.idle)
            return
        }
        if let degraded = result.degradedReason {
            // Text went in, but the LLM step was skipped — surface why.
            fail(degraded)
        } else {
            setState(.done)
            scheduleReturnToIdle()
        }
    }

    /// Ends an in-flight dictation without inserting anything.
    func cancelCurrentDictation() {
        processingTask?.cancel()
        processingTask = nil
        Task { [recorder] in await recorder.cancel() }
        setState(.idle)
    }

    // MARK: - Local services

    /// Checks Whisper and Ollama up front so problems surface before the user speaks.
    func checkLocalServices() async {
        let configuration = settings.snapshot()
        let recognizer = makeRecognizer(configuration.speech)
        let llm = makeLLM(configuration.llm)

        var problems: [String] = []

        do {
            try await recognizer.preflight()
        } catch let error as VoiceFlowError {
            problems.append(error.shortMessage)
        } catch {
            problems.append(error.localizedDescription)
        }

        do {
            try await llm.preflight()
        } catch let error as VoiceFlowError {
            problems.append(error.shortMessage)
        } catch {
            problems.append(error.localizedDescription)
        }

        serviceStatus = problems.isEmpty ? nil : problems.joined(separator: "\n\n")
    }

    // MARK: - State

    private func setState(_ newState: DictationState) {
        state = newState
        indicator.update(newState)
    }

    private func fail(_ error: VoiceFlowError) {
        setState(.failed(error))
        scheduleReturnToIdle(after: .seconds(5))

        if error.isPermissionError {
            SystemSettingsLink.open(for: error)
        }
    }

    private func scheduleReturnToIdle(after delay: Duration = .seconds(1)) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            // Only clear if nothing new started in the meantime.
            if !self.state.isBusy {
                self.setState(.idle)
            }
        }
    }
}

/// Deep links into the relevant Privacy & Security pane.
enum SystemSettingsLink {
    static func open(for error: VoiceFlowError) {
        let anchor: String
        switch error {
        case .microphonePermissionDenied:
            anchor = "Privacy_Microphone"
        case .accessibilityPermissionDenied:
            anchor = "Privacy_Accessibility"
        default:
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
