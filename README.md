# VoiceFlow

A local, privacy-first voice dictation utility for macOS.

Hold a hotkey, speak, release. VoiceFlow transcribes what you said with
[whisper.cpp](https://github.com/ggerganov/whisper.cpp), cleans it up with a local LLM
served by [Ollama](https://ollama.com), and pastes the result into whatever app you were
already typing in.

```
⌥Space down  →  🎙 recording
⌥Space up    →  ✨ whisper → local LLM → paste
```

**Nothing leaves your Mac.** The only network request VoiceFlow ever makes is to a
loopback address (`http://localhost:11434` by default). See [Privacy](#privacy).

---

## Status

The application is complete and the architecture is documented below, but **it has not
yet been compiled or run** — it was written in a Linux container with no macOS SDK,
Xcode, or Swift toolchain available. Expect to fix compile errors on first build.
See [Known limitations](#known-limitations) for the specific areas most likely to need
attention.

---

## Requirements

| | |
|---|---|
| macOS | 14.0 (Sonoma) or later |
| Xcode | 16.0 or later (the project uses file-system-synchronized groups) |
| Swift | 5.9+ (ships with Xcode 16); the project builds in Swift 5 language mode |
| Hardware | Apple Silicon recommended — whisper.cpp uses Metal, and Ollama uses the GPU |
| Disk | ~500 MB for the `small` Whisper model, ~5 GB for `qwen3:8b` |
| RAM | 16 GB comfortably runs `small` + `qwen3:8b` together |

An Intel Mac works but transcription falls back to CPU. Consider the `base` Whisper
model and a smaller LLM such as `qwen3:4b`.

---

## Setup

### 1. Install Homebrew

If you don't already have it:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. Install whisper.cpp

```bash
brew install whisper-cpp
```

This installs `whisper-cli` into `/opt/homebrew/bin` (Apple Silicon) or
`/usr/local/bin` (Intel). The Homebrew bottle is built with Metal support, so
transcription runs on the GPU on Apple Silicon with no extra configuration.

VoiceFlow searches both prefixes automatically. If you built whisper.cpp yourself, set
the binary path under **Settings → Speech**.

Recent bottles also install `whisper-server`. If it is present, VoiceFlow starts it
once at launch — bound to `127.0.0.1` on a port picked at random — and transcribes by
posting to it, so the model weights stay loaded between dictations instead of being
re-read from disk every time. If it is missing, VoiceFlow falls back to `whisper-cli`
and everything keeps working. The menu says which backend is live, and
**Settings → Speech → Engine** forces one or the other.

> **Why a subprocess and not a linked library?** Driving whisper.cpp out of process
> keeps the Xcode project free of a C bridging target and picks up whatever
> acceleration your installed build has. `SpeechRecognizer` is a protocol precisely so
> an in-process binding can replace this later without touching the pipeline — see
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### 3. Install a Whisper model

```bash
./scripts/download-whisper-model.sh small
```

This downloads `ggml-small.bin` (~466 MB) to
`~/Library/Application Support/VoiceFlow/models/`.

Other sizes work too — `tiny`, `base`, `small`, `medium`, `large-v3-turbo`. Pick one in
**Settings → Speech**. `small` is the default: accurate enough for dictation, fast
enough to feel instant.

### 4. Install Ollama and pull a model

```bash
brew install ollama
ollama serve          # or: brew services start ollama
ollama pull qwen3:8b
```

`qwen3:8b` is the default. Any instruct model works; set the name in
**Settings → LLM**. `qwen3:4b` is a good choice on a 16 GB machine.

> VoiceFlow sends `"think": false` with every request, so reasoning models such as
> qwen3 skip their `<think>` preamble rather than spending your token budget on it.
> Any reasoning block that slips through is stripped before insertion.

### 5. Verify the setup

```bash
./scripts/check-setup.sh
```

This checks the same things the app checks at launch and prints the exact command to
fix anything missing.

### 6. Build and run

```bash
open VoiceFlow.xcodeproj
```

Select the **VoiceFlow** scheme and press ⌘R. Or from the command line:

```bash
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow -configuration Debug build
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow test
```

A waveform icon appears in the menu bar. There is no Dock icon and no main window —
VoiceFlow is an accessory app.

---

## Permissions

VoiceFlow needs two permissions. It asks for both on first launch.

### Microphone

Prompted automatically the first time you record. If you dismissed it:

**System Settings → Privacy & Security → Microphone → VoiceFlow**

### Accessibility

Required for **both** halves of the app:

- reading the global hotkey while another app is focused (`CGEventTap`)
- pasting into the focused app (synthetic ⌘V)

**System Settings → Privacy & Security → Accessibility → VoiceFlow**

> **After every rebuild in Xcode, you may need to re-grant Accessibility.** macOS keys
> this permission to the code signature, and a locally built app is ad-hoc signed with
> a signature that changes on each build. Remove the stale VoiceFlow entry with the
> **−** button and re-add the newly built app. Signing with a Developer ID certificate
> makes the grant stick.

---

## Using it

1. Focus the app you want to type into.
2. Hold **⌥Space**.
3. Speak.
4. Release.

A small pill appears near the bottom of the screen: `🎙 Recording…`, then
`✨ Processing…`, then `✓ Done`. It disappears on its own and never takes focus.

### Modes

Set from the menu bar or **Settings → General**:

| Mode | What it does |
|---|---|
| **Dictate** *(default)* | Removes filler words, adds punctuation, fixes grammar. Keeps your wording. |
| **Polish** | Rewrites into clear, well-structured prose. Preserves every fact and your intent. |
| **Exact** | Near-verbatim. Only punctuation and unambiguous transcription repairs. |

**Terminals and code editors are always forced to Exact**, whatever mode you have
selected — a "polished" shell command is a broken shell command.

### Example

Spoken:

> hey john um I wanted to follow up on the thing we discussed yesterday I think we
> should move the launch to next tuesday because we're still waiting on the api
> integration

Inserted (Dictate mode):

> Hey John,
>
> I wanted to follow up on the thing we discussed yesterday. I think we should move the
> launch to next Tuesday because we're still waiting on the API integration.

---

## Privacy

> All speech recognition and LLM processing happens locally on this Mac.
>
> VoiceFlow does not upload your recordings or transcripts.

Concretely:

- **Audio** is held in memory as 16 kHz mono samples. It is written to a temporary WAV
  only because `whisper-cli` needs a file path, and that file is deleted in a `defer`
  block that runs on every path out of the pipeline — success, failure, and
  cancellation alike. Any stragglers from a crash are cleared at launch and quit.
- **Speech recognition** runs in a local `whisper-cli` subprocess.
- **Cleanup** runs against a local Ollama server. This is the app's only outbound
  request, it only ever targets the configured endpoint, and the `URLSession` is
  `.ephemeral` so nothing is cached to disk.
- **Transcripts** are never written to disk and never logged.
- **Clipboard** contents are snapshotted before pasting and restored ~350 ms after,
  including rich representations, not just plain text.

There is **no** analytics, telemetry, crash reporting, remote logging, cloud LLM,
remote speech API, user account, backend, or tracking SDK. There is no `Package.swift`
dependency list because there are no third-party dependencies at all — only Apple
frameworks.

You can verify the network claim yourself:

```bash
# Every URL literal in the source. Only the Ollama endpoint and the model
# download script (which you run manually, not the app) should appear.
grep -rn "https\?://" VoiceFlow/
```

### Why the App Sandbox is off

A sandboxed app cannot create a `CGEventTap`, cannot post synthetic events to other
applications, and cannot use the Accessibility API. Those three things *are* global
push-to-talk and pasting into the focused app, and no entitlement grants them to a
sandboxed app. VoiceFlow ships unsandboxed, as every comparable dictation utility does.
The reasoning is recorded in `Config/VoiceFlow.entitlements`.

---

## Architecture

```
VoiceFlow/
├── App/          entry point, delegate, menu bar, coordinator, settings window
├── Audio/        AudioRecorder (actor), AudioBuffer (lock-guarded), WAVWriter
├── Hotkeys/      GlobalHotkeyManager (CGEventTap), HotkeyStateMachine (pure)
├── Speech/       SpeechRecognizer protocol, WhisperCppRecognizer
├── LLM/          LLMProvider protocol, OllamaProvider, OllamaWire (pure)
├── Processing/   TranscriptionPipeline (actor), PromptBuilder, TextSanitizer
├── Context/      ApplicationContext, frontmost-app detection
├── Paste/        TextInsertionManager (clipboard + CGEvent)
├── UI/           RecordingIndicator, SettingsView, StatusView (SwiftUI)
├── Models/       AppSettings, PipelineConfiguration, DictationMode, errors
└── Support/      ProcessRunner, LaunchAtLogin
```

Two rules hold the design together:

**Every external dependency sits behind a protocol.** `SpeechRecognizer`,
`LLMProvider`, `TextInserting`, and `FrontmostApplicationProviding` each have a real
implementation and a mock. Swapping Ollama for MLX or Apple Foundation Models means
adding a type, not editing the pipeline.

**Every decision worth testing is a pure function.** Prompt assembly, wire format,
output sanitizing, hotkey transitions, and WAV encoding have no I/O, so they are
covered by fast unit tests instead of manual verification.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the data flow, threading model,
and the reasoning behind the less obvious choices.

---

## Testing

```bash
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow test
```

The full pipeline is covered without Whisper, Ollama, or a window server:

```
MockSpeechRecognizer → MockLLMProvider → MockTextInsertionManager
```

| Suite | Covers |
|---|---|
| `OllamaWireTests` | request generation, response parsing, error mapping, model matching |
| `TranscriptionPipelineTests` | full flow, degraded operation, cancellation, audio cleanup |
| `PromptBuilderTests` | mode rules, app-context overrides, transcript delimiting |
| `TextSanitizerTests` | reasoning blocks, code fences, quotes, fallback cleanup |
| `HotkeyStateMachineTests` | press/release ordering, auto-repeat, event consumption |
| `ApplicationContextTests` | bundle-ID classification and the behaviour it drives |
| `AppSettingsTests` | persistence round-trips, snapshot isolation, bad stored values |
| `WAVWriterTests` | header layout, chunk sizes, sample clamping |
| `AudioBufferTests` | capping, level metering, concurrent appends |
| `VoiceFlowErrorTests` | the exact wording of every user-facing failure |
| `WhisperCppRecognizerTests` | CLI flags, binary discovery, preflight, stderr summarising |
| `WhisperServerRecognizerTests` | server discovery and flags, port reservation, pid-file safety, multipart encoding, response parsing |
| `TextInsertionManagerTests` | paste returns promptly, clipboard restore, failure leaves the text |
| `DiagnosticsTests` | duration conversion, the timing summary line, its privacy |

---

## Troubleshooting

Run `./scripts/check-setup.sh` first — it diagnoses most of these.

**Nothing happens when I press ⌥Space**
Accessibility permission is missing or stale. Check
**System Settings → Privacy & Security → Accessibility**, remove any old VoiceFlow
entry with **−**, and re-add the app you just built. The menu bar shows the current
status.

**"Ollama is not running."**
Start it: `ollama serve`, or `brew services start ollama` to run it at login. Confirm
with `curl http://localhost:11434/api/tags`.

**"The model qwen3:8b is not installed."**
`ollama pull qwen3:8b`, or point Settings → LLM at a model you already have.

**"The whisper.cpp command line tool was not found."**
`brew install whisper-cpp`. If you built it yourself, set the binary path in
**Settings → Speech** — the error message lists every path that was searched.

**"The Whisper model is missing"**
`./scripts/download-whisper-model.sh small`.

**Text appears in the wrong app**
VoiceFlow captures the frontmost app at the moment you press the hotkey. If you switch
apps mid-dictation, the text goes to the app you started in. This is deliberate.

**Text doesn't appear, but ⌘V works**
That app blocks synthetic paste. Turn on **Type text instead of pasting** in
**Settings → General**. Slower, but it works in secure fields and some terminals.

**My clipboard was replaced**
The clipboard is restored ~350 ms after pasting. If the paste itself failed, the text
is left on the clipboard deliberately so your words aren't lost — press ⌘V.

**Transcription is slow**
Use a smaller Whisper model (`base`), a smaller LLM (`qwen3:4b`), or set
**Settings → Speech → Language** explicitly instead of auto-detect.

**It transcribed something I didn't say**
Whisper hallucinates on silence. VoiceFlow discards recordings under 0.2 s and strips
`[BLANK_AUDIO]`-style annotations, but a noisy room can still produce artefacts. Try
`medium`, or Exact mode.

---

## Known limitations

These are real and deliberate; none is a crash.

- **Unverified build.** Written without access to a macOS toolchain. See
  [Status](#status).
- **Model reload per dictation, on the CLI backend only.** `whisper-cli` loads weights
  on each invocation, adding a few hundred milliseconds. Installing `whisper-server`
  (or leaving **Settings → Speech → Engine** on Automatic, which prefers it) removes
  this; forcing the CLI backend brings it back.
- **Trailing key-up leaks.** If you release ⌥ before Space, the state machine ends the
  utterance on the modifier drop and the subsequent Space key-up is no longer consumed.
  A key-up with no matching key-down is a no-op in practice, but it is not swallowed.
  Covered by `testTrailingKeyUpIsNotConsumedOnceRecordingHasEnded`.
- **Clipboard restore is time-based.** 350 ms is a heuristic. An app that reads the
  pasteboard lazily could miss the text; one that reads it slowly could see the restore.
- **Launch at login needs a stable signature.** `SMAppService` registration typically
  fails for an ad-hoc-signed debug build run from DerivedData.
- **One language per dictation.** Whisper's language is a setting, not per-utterance.

---

## Licence

MIT for this project's own code. whisper.cpp, the GGML model weights, Ollama, and any
model you pull each carry their own licences.
