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
    /// Which speech backend is actually in use, shown alongside the status. Nil until
    /// the first check, or when the recognizer doesn't have a choice to report.
    @Published private(set) var speechBackendStatus: String?

    private let settings: AppSettings
    private let recorder: AudioRecorder
    private let hotkeys: GlobalHotkeyManager
    private let indicator: RecordingIndicatorController
    private let applicationProvider: any FrontmostApplicationProviding

    /// Captured at key-down, before any VoiceFlow UI appears, so it reflects the app
    /// the user was actually typing into.
    private var pendingContext: ApplicationContext = .unknown
    private var processingTask: Task<Void, Never>?
    /// Fire-and-forget warmup started at key-down.
    private var warmupTask: Task<Void, Never>?
    /// Live incremental transcription, when the setting and the backend allow it.
    private var streaming: StreamingTranscriber?

    /// Overridable so tests and future backends can substitute implementations.
    /// These are the *factories*; the instances they produce are cached below and
    /// reused across dictations, so a factory is called again only when the settings
    /// it depends on actually change.
    var makeRecognizer: (SpeechSettings) -> any SpeechRecognizer = { AdaptiveSpeechRecognizer(settings: $0) }
    var makeLLM: (LLMSettings) -> any LLMProvider = { OllamaProvider(settings: $0) }
    var makeInserter: (PipelineConfiguration) -> any TextInserting = {
        TextInsertionManager(useDirectTyping: $0.useDirectTyping)
    }

    /// Long-lived pipeline components, each keyed on the slice of configuration it
    /// actually depends on.
    ///
    /// Every utterance used to build a fresh recognizer, LLM provider, and inserter.
    /// The provider was the expensive one: each `OllamaProvider` constructed its own
    /// ephemeral `URLSession`, so every dictation opened a new connection to
    /// localhost and threw away the keep-alive. Keying on the settings slice rather
    /// than the whole snapshot means switching mode mid-session doesn't tear down a
    /// resident speech backend.
    private var cachedRecognizer: (key: SpeechSettings, value: any SpeechRecognizer)?
    private var cachedLLM: (key: LLMSettings, value: any LLMProvider)?
    private var cachedInserter: (key: Bool, value: any TextInserting)?

    private func recognizer(for settings: SpeechSettings) -> any SpeechRecognizer {
        if let cached = cachedRecognizer, cached.key == settings { return cached.value }
        // Changing the speech settings retires the old backend, which for the
        // resident server means terminating its child process.
        cachedRecognizer?.value.shutdown()
        let recognizer = makeRecognizer(settings)
        cachedRecognizer = (settings, recognizer)
        return recognizer
    }

    /// Refreshes the "which speech backend is live" line from the current recognizer.
    private func refreshSpeechBackendStatus() {
        speechBackendStatus = (cachedRecognizer?.value as? AdaptiveSpeechRecognizer)?.statusLine
    }

    private func llm(for settings: LLMSettings) -> any LLMProvider {
        if let cached = cachedLLM, cached.key == settings { return cached.value }
        let provider = makeLLM(settings)
        cachedLLM = (settings, provider)
        return provider
    }

    /// Keyed on `useDirectTyping` alone: it is the only field the real inserter reads,
    /// and rebuilding on every mode change would discard the pending clipboard
    /// restore that `TextInsertionManager` now owns.
    private func inserter(for configuration: PipelineConfiguration) -> any TextInserting {
        if let cached = cachedInserter, cached.key == configuration.useDirectTyping {
            return cached.value
        }
        let inserter = makeInserter(configuration)
        cachedInserter = (configuration.useDirectTyping, inserter)
        return inserter
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
        warmupTask?.cancel()
        // Quitting inside the clipboard-restore window must not leave the dictated
        // text on the user's clipboard.
        cachedInserter?.value.flushPendingWork()
        // Synchronous, and it must stay that way: this is the last chance to kill a
        // resident whisper-server before the process goes away.
        cachedRecognizer?.value.shutdown()
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
        let configuration = settings.snapshot()

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

        startWarmup(configuration: configuration, context: pendingContext)
        startStreamingIfEnabled(configuration: configuration)
    }

    // MARK: - Warmup

    /// Gets both engines ready while the user is still speaking.
    ///
    /// Everything here is best-effort and invisible: it never blocks recording, never
    /// changes state, and never surfaces an error. The engines are about to be asked
    /// for real work regardless, so a failed warmup costs nothing beyond the saving it
    /// would have made.
    ///
    /// With `keep_alive: "60m"` already set, this mostly buys back the multi-second
    /// penalty on the first dictation after launch, or after Ollama evicted the model.
    private func startWarmup(configuration: PipelineConfiguration, context: ApplicationContext) {
        let recognizer = recognizer(for: configuration.speech)
        let llm = llm(for: configuration.llm)

        warmupTask?.cancel()
        // Detached: warmup must not occupy the main actor while the user is talking.
        warmupTask = Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await recognizer.warmUp()
                }
                group.addTask {
                    guard !Task.isCancelled else { return }
                    // num_predict 0: loads the weights and fills the prefix cache with
                    // the exact system prompt the real request will send, then stops.
                    let request = PromptBuilder.warmupRequest(
                        mode: configuration.mode,
                        context: context,
                        settings: configuration.llm
                    )
                    _ = try? await llm.generate(request)
                }
            }
        }
    }

    // MARK: - Incremental transcription

    /// Starts transcribing while recording, when the setting is on and the resident
    /// backend is actually live. Under the CLI backend this would spawn a whole
    /// process per window, which is slower than doing nothing.
    private func startStreamingIfEnabled(configuration: PipelineConfiguration) {
        streaming = nil
        guard configuration.speech.streamingEnabled else { return }

        let recognizer = recognizer(for: configuration.speech)
        guard (recognizer as? AdaptiveSpeechRecognizer)?.active == .server else { return }

        let transcriber = StreamingTranscriber(
            recognizer: recognizer,
            source: recorder.sampleSource
        )
        streaming = transcriber
        Task { await transcriber.start() }
    }

    private func endRecording() {
        guard case .recording = state else { return }

        setState(.processing(.transcribing))
        // The user has stopped speaking, so a warmup still in flight is only
        // competing with the real request for the same backend.
        warmupTask?.cancel()
        warmupTask = nil

        let configuration = settings.snapshot()
        let context = pendingContext
        let streaming = self.streaming
        self.streaming = nil

        processingTask = Task { [recorder, weak self] in
            do {
                let captured = try await recorder.stop()
                // nil means "nothing usable was transcribed early" — the pipeline
                // then does the whole utterance in one pass, exactly as before.
                let stitched = await streaming?.finish(allSamples: captured.samples)
                try await self?.process(
                    captured: captured,
                    context: context,
                    configuration: configuration,
                    precomputedTranscript: stitched
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
        configuration: PipelineConfiguration,
        precomputedTranscript: String? = nil
    ) async throws {
        // When the incremental path produced a transcript, it reaches the pipeline
        // through the same `SpeechRecognizer` seam as everything else, so the
        // pipeline never learns that transcription can finish before key-up.
        let speech: any SpeechRecognizer = precomputedTranscript.map {
            PrecomputedTranscriptRecognizer(transcript: $0)
        } ?? recognizer(for: configuration.speech)

        let pipeline = TranscriptionPipeline(
            recognizer: speech,
            llm: llm(for: configuration.llm),
            inserter: inserter(for: configuration),
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

        // A dictation can flip the backend — the server may have died and the CLI
        // picked it up — so the reported backend is refreshed after every run.
        refreshSpeechBackendStatus()

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
        warmupTask?.cancel()
        warmupTask = nil
        if let streaming {
            Task { await streaming.cancel() }
            self.streaming = nil
        }
        Task { [recorder] in await recorder.cancel() }
        setState(.idle)
    }

    // MARK: - Local services

    /// Checks Whisper and Ollama up front so problems surface before the user speaks.
    func checkLocalServices() async {
        let configuration = settings.snapshot()
        // The same instances the pipeline will use, so this warms the cache rather
        // than building throwaway components.
        let recognizer = recognizer(for: configuration.speech)
        let llm = llm(for: configuration.llm)

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
        refreshSpeechBackendStatus()
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
