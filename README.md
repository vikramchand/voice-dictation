# VoiceFlow

A local, privacy-first voice dictation utility for macOS.

Hold a hotkey, speak, release. VoiceFlow transcribes what you said with
[whisper.cpp](https://github.com/ggerganov/whisper.cpp), cleans it up with a local LLM
served by [Ollama](https://ollama.com), and pastes the result into whatever app you were
already typing in.

```
fn down  →  🎙 Recording…
fn up    →  Transcribing… → Processing… → Inserting… → Done
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

The same applies to the latency work: the resident `whisper-server` backend, the
key-down warmup, and incremental transcription are written and unit-tested against
mocks, but none has been run against a real whisper.cpp or Ollama. The per-stage
timings needed to confirm the savings come from the instrumentation described under
[Measuring](#measuring).

---

## Requirements

| | |
|---|---|
| macOS | 14.0 (Sonoma) or later — `MACOSX_DEPLOYMENT_TARGET = 14.0` |
| Xcode | 15.0 or later (`objectVersion = 56`, Swift 5 language mode) |
| Hardware | Apple Silicon recommended — whisper.cpp uses Metal, and Ollama uses the GPU |
| Disk | ~150 MB for the `base.en` Whisper model, ~2 GB for `qwen2.5:3b` |
| RAM | 8 GB comfortably runs `base.en` + `qwen2.5:3b` together |

An Intel Mac works but transcription falls back to CPU.

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

VoiceFlow searches `/opt/homebrew/bin`, `/usr/local/bin`, and `/opt/local/bin`, then
everything on `PATH`, for `whisper-cli`, `whisper-cpp`, `whisper`, and `main`, in that
order. If you built whisper.cpp yourself, set the binary path under
**Settings → Speech**.

Recent bottles also install `whisper-server`. If it is present, VoiceFlow starts it —
bound to `127.0.0.1` on a port the kernel assigns — and transcribes by posting to it,
so the model weights stay loaded between dictations instead of being re-read from disk
every time. The server comes up on the first preflight at launch, or at the first
hotkey press, whichever happens first. If `whisper-server` is missing, VoiceFlow falls
back to `whisper-cli` and everything keeps working. The menu says which backend is
live, and **Settings → Speech → Engine** forces one or the other.

> **Why a subprocess and not a linked library?** Driving whisper.cpp out of process
> keeps the Xcode project free of a C bridging target and picks up whatever
> acceleration your installed build has. `SpeechRecognizer` is a protocol precisely so
> an in-process binding can replace this later without touching the pipeline — see
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### 3. Install a Whisper model

```bash
./scripts/download-whisper-model.sh base.en
```

This downloads `ggml-base.en.bin` to
`~/Library/Application Support/VoiceFlow/models/`.

On first launch, with nothing stored in settings, VoiceFlow picks its model path in
this order: `ggml-base.en.bin` if it exists, then `ggml-base.bin`, otherwise
`ggml-small.bin` (whether or not that file is there). So `base.en` is the model you get
by default, and `small` is the path you are pointed at if you have installed neither
`base`.

The script accepts `tiny`, `tiny.en`, `base`, `base.en`, `small`, `small.en`, `medium`,
`medium.en`, `large-v3`, and `large-v3-turbo`; with no argument it downloads `small`.
The **Settings → Speech → Model** picker lists only `tiny`, `base`, `small`, `medium`,
and `large-v3-turbo` — an English-only model such as `base.en` is a valid choice, it
just shows up in the picker as *Custom…* with its path in the field below.

### 4. Install Ollama and pull a model

```bash
brew install ollama
ollama serve          # or: brew services start ollama
ollama pull qwen2.5:3b
```

`qwen2.5:3b` is the default. Transcript cleanup is near-mechanical — punctuation,
capitalization, dropping filler — and a 3B does it about as well as a 7B while decoding
two to three times faster, which here is the difference between a pause and no pause.
Any instruct model works; set the name in **Settings → LLM**, and a model you have
already chosen is never overwritten by a change to the default.

> VoiceFlow sends `"think": false` with every request, so reasoning models such as
> qwen3 skip their `<think>` preamble rather than spending your token budget on it.
> Any reasoning block that slips through is stripped before insertion, as are
> "We are given…" / "Steps:" monologues.

### 5. Verify the setup

```bash
./scripts/check-setup.sh
```

It checks the platform, the whisper.cpp binary, the installed model files, and a
reachable Ollama, and prints the exact command to fix anything missing.

> One caveat: the script's Ollama check is hard-coded to `qwen3:8b` and has not
> followed the app's default of `qwen2.5:3b`. Expect that one line to report a missing
> model unless you have pulled `qwen3:8b` as well. Everything else it checks matches
> what the app does at launch. Override the endpoint with
> `VOICEFLOW_OLLAMA_ENDPOINT`.

### 6. Build and run

```bash
open VoiceFlow.xcodeproj
```

Select the **VoiceFlow** scheme and press ⌘R. Or from the command line:

```bash
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow -configuration Debug build
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow test
```

Source files are listed individually in the project (there are no file-system
synchronized groups), so a new `.swift` file has to be added to the target explicitly.

---

## First launch

VoiceFlow runs as a regular app: it has a Dock icon, and `LSUIElement` is `false`.
On launch it:

1. clears any stale WAVs left in `$TMPDIR/VoiceFlow` and kills a `whisper-server`
   orphaned by a previous unclean exit,
2. installs the waveform menu bar item and checks that Whisper and Ollama are reachable,
3. asks for **Microphone** access up front — rather than mid-utterance, where the
   dialog would eat the start of what you said,
4. **opens the settings window**, so there is immediate visual feedback that the app
   is running,
5. prompts for **Accessibility** if it has not already been granted.

The floating recording indicator is a non-activating panel and never takes focus, but
the settings window is an ordinary window — close it before dictating if you want the
text to land somewhere else.

---

## Permissions

VoiceFlow needs two permissions, and asks for both on first launch.

### Microphone

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
2. Hold **fn** (the Globe key).
3. Speak.
4. Release.

A small pill appears at the bottom centre of whichever screen has the pointer, 96 pt
above the top of the Dock: `Recording…` with a five-bar level meter, then
`Transcribing…`, `Processing…`, `Inserting…`, and `Done`. It never takes focus, hides
itself a second after `Done`, and lingers five seconds on a failure so you can read it.

The hotkey is rebindable in **Settings → General**: click the button and press the
combination you want. `fn` on its own is accepted; any other binding needs at least one
modifier, because a bare key would fire on every keystroke system-wide. Escape cancels
the recording. Releasing the modifier before the key ends the utterance just as
releasing the key does.

While you hold the key, VoiceFlow is already working: it starts `whisper-server` if it
isn't up and sends Ollama a zero-token request carrying the exact system prompt the real
request will use, so the weights are loaded and the prefix cache is warm before you stop
speaking. All of it is best-effort and invisible, and it is cancelled the moment you
release.

### Modes

Set from the menu bar or **Settings → General**:

| Mode | What it does |
|---|---|
| **Dictate** *(default)* | Removes filler words, adds punctuation, fixes grammar and false starts. Keeps your wording. |
| **Polish** | Rewrites into clear, well-structured prose. Preserves every fact and your intent. |
| **Exact** | Near-verbatim. Only punctuation and unambiguous transcription repairs. |

**Terminals and code editors are always forced to Exact**, whatever mode you have
selected — a "polished" shell command is a broken shell command. The app you were in is
also worth a one-line formatting hint: chat apps get "keep it short, no invented
greeting", email gets paragraph breaks, notes keeps your list structure. Browsers and
anything unrecognized get no hint at all.

### Settings reference

Everything, with the value you get if you never touch it.

**General**

| Setting | Default |
|---|---|
| Global hotkey | `fn` |
| Mode | Dictate |
| Launch at login | off |
| Insert plain transcript if the LLM is unavailable | on |
| Skip the LLM for short, clean phrases | on |
| Type text instead of pasting | off |

**Speech**

| Setting | Default |
|---|---|
| Model | `ggml-base.en.bin`, else `ggml-base.bin`, else `ggml-small.bin` |
| Language | English (`en`) — naming the language is faster and more accurate than auto-detect |
| Engine | Automatic (resident `whisper-server` when installed, otherwise `whisper-cli`) |
| Transcribe while I speak | off, and unavailable when the engine is forced to the CLI |
| whisper.cpp binary | empty, i.e. auto-discover |

**LLM**

| Setting | Default |
|---|---|
| Provider | Ollama (local), not switchable in the UI |
| Endpoint | `http://localhost:11434` |
| Model | `qwen2.5:3b` |
| Temperature | 0.10 |
| Max tokens | 512 — a ceiling, not a target; see [Measuring](#measuring) |

Settings are read into an immutable snapshot — once at key-down, for the warmup and the
incremental path, and again at key-up for the run itself — so changing one mid-dictation
cannot alter work already in flight.

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

Short, clean utterances skip the model entirely. "On my way", "sounds good, thanks",
"restart the server" — eight words or fewer, with no filler word ("um", "uh", …), no
filler phrase ("you know", "sort of", …), no repeated word and no stutter — are
capitalized and terminated deterministically and inserted immediately.
Anything longer, or with any sign of disfluency, goes to the LLM. Turn the toggle off in
**Settings → General** to send every dictation to the model.

---

## Privacy

> All speech recognition and LLM processing happens locally on this Mac.
>
> VoiceFlow does not upload your recordings or transcripts.

Concretely:

- **Audio** is held in memory as 16 kHz mono samples, capped at five minutes. It is
  written to a temporary WAV in `$TMPDIR/VoiceFlow` only because whisper.cpp needs a
  file path, and that file is deleted in a `defer` block that runs on every path out of
  the pipeline — success, failure, and cancellation alike. Incremental chunks get the
  same treatment. Any stragglers from a crash are cleared at launch and at quit.
- **Speech recognition** runs in a local whisper.cpp subprocess: either `whisper-cli`,
  or a `whisper-server` bound explicitly to `127.0.0.1` whose only client is VoiceFlow
  itself. That server is terminated at quit, and a copy left behind by a crash is killed
  at the next launch — but only after `ps` confirms the recorded pid is still running
  something called whisper-server.
- **Cleanup** runs against a local Ollama server. This is the app's only outbound
  request, it only ever targets the configured endpoint, and the `URLSession` is
  `.ephemeral` with no cache and no cookie storage.
- **Transcripts** are never written to disk and never logged, at any log level.
- **Clipboard** contents are snapshotted before pasting and restored ~350 ms after,
  including rich representations, not just plain text. Quitting inside that window
  flushes the restore immediately rather than leaving your dictation on the clipboard.

There is **no** analytics, telemetry, crash reporting, remote logging, cloud LLM,
remote speech API, user account, backend, or tracking SDK. There is no `Package.swift`
dependency list because there are no third-party dependencies at all — only Apple
frameworks.

You can verify the network claim yourself:

```bash
# Every URL literal in the source. Only the Ollama endpoint, the loopback
# whisper-server, and the model download script (which you run manually, not the
# app) should appear.
grep -rn "https\?://" VoiceFlow/ scripts/
```

`Config/Info.plist` declares no `NSAppTransportSecurity` exception, deliberately: ATS
does not apply to loopback, so plain HTTP to `127.0.0.1` already works and
`NSAllowsArbitraryLoads` would grant far more than this app needs.

### Why the App Sandbox is off

A sandboxed app cannot create a `CGEventTap`, cannot post synthetic events to other
applications, and cannot use the Accessibility API. Those three things *are* global
push-to-talk and pasting into the focused app, and no entitlement grants them to a
sandboxed app. VoiceFlow ships unsandboxed, as every comparable dictation utility does.
Hardened Runtime is on, with `com.apple.security.device.audio-input` for the
microphone. The reasoning is recorded in `Config/VoiceFlow.entitlements`.

---

## Architecture

```
VoiceFlow/
├── App/          entry point, delegate, menu bar, coordinator, settings window
├── Audio/        AudioRecorder (actor), AudioBuffer (lock-guarded), WAVWriter
├── Hotkeys/      GlobalHotkeyManager (CGEventTap), HotkeyStateMachine (pure)
├── Speech/       SpeechRecognizer protocol, AdaptiveSpeechRecognizer,
│                 WhisperCppRecognizer, WhisperServerRecognizer + Supervisor + Wire,
│                 StreamingTranscriber, SpeechSegmenter (pure)
├── LLM/          LLMProvider protocol, OllamaProvider, OllamaWire (pure)
├── Processing/   TranscriptionPipeline (actor), PromptBuilder, TextSanitizer,
│                 CleanupHeuristics (all but the pipeline pure)
├── Context/      ApplicationContext, frontmost-app detection
├── Paste/        TextInsertionManager (clipboard + CGEvent)
├── UI/           RecordingIndicator, SettingsView, StatusView, HotkeyRecorderView
├── Models/       AppSettings, PipelineConfiguration, DictationMode, DictationState,
│                 HotkeyShortcut, errors
└── Support/      ProcessRunner, LaunchAtLogin, LocalPort, Diagnostics
```

One dictation, end to end:

```
fn down → capture the frontmost app → AudioRecorder (actor) → warm up both engines
        → optionally transcribe each pause as you reach it
fn up   → WAV → transcribe → cleanup (or skip it) → paste → restore clipboard
```

Two rules hold the design together:

**Every external dependency sits behind a protocol.** `SpeechRecognizer`,
`LLMProvider`, `TextInserting`, `FrontmostApplicationProviding`, and `KeyValueStore`
each have a real implementation and a mock. Swapping Ollama for MLX or Apple Foundation
Models means adding a type, not editing the pipeline. The two Whisper backends are the
proof: `AdaptiveSpeechRecognizer` picks between them and falls back, and the pipeline
never learns there is more than one.

**Every decision worth testing is a pure function.** Prompt assembly, wire formats,
output sanitizing, hotkey transitions, cut-point selection, cleanup routing, token
budgeting, and WAV encoding have no I/O, so they are covered by fast unit tests instead
of manual verification.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the data flow, threading model,
and the reasoning behind the less obvious choices.

---

## Testing

```bash
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow test
```

Around 250 tests. The full pipeline is covered without Whisper, Ollama, or a window
server:

```
MockSpeechRecognizer → MockLLMProvider → MockTextInsertionManager
```

| Suite | Covers |
|---|---|
| `OllamaWireTests` | request generation, response parsing, error mapping, model matching |
| `TranscriptionPipelineTests` | full flow, degraded operation, cancellation, audio cleanup |
| `PromptBuilderTests` | mode rules, app-context overrides, transcript delimiting, token budget, warmup/real prompt agreement |
| `TextSanitizerTests` | reasoning blocks and monologues, code fences, quotes, fallback cleanup |
| `HotkeyStateMachineTests` | press/release ordering, auto-repeat, modifier-only keys, event consumption |
| `ApplicationContextTests` | bundle-ID classification and the behaviour it drives |
| `AppSettingsTests` | persistence round-trips, snapshot isolation, bad stored values |
| `WAVWriterTests` | header layout, chunk sizes, sample clamping |
| `AudioBufferTests` | capping, level metering, concurrent appends, non-destructive read-ahead |
| `VoiceFlowErrorTests` | the exact wording of every user-facing failure |
| `WhisperCppRecognizerTests` | CLI flags, binary discovery and caching, preflight, stderr summarising |
| `WhisperServerRecognizerTests` | server discovery and flags, port reservation, pid-file safety, multipart encoding, response parsing |
| `StreamingTranscriberTests` | where audio may be cut, and stitched output matching one-shot output |
| `CleanupHeuristicsTests` | which transcripts are worth an LLM round trip |
| `TextInsertionManagerTests` | paste returns promptly, clipboard restore, failure leaves the text |
| `DiagnosticsTests` | duration conversion, the timing summary line, its privacy |

---

## Measuring

Every dictation is instrumented. `os_signpost` intervals wrap each stage —
`dictation`, `transcribe`, `cleanup`, `insert`, plus `whisper-cli`,
`whisper-server-start`, `whisper-server-inference`, and `ollama-generate` — and they are
always emitted, because `OSSignposter` costs nothing unless something is recording. Open
Instruments with the **os_signpost** template, or:

```bash
xctrace record --template 'os_signpost' --attach VoiceFlow --output dictation.trace
```

For a one-line-per-dictation summary in Console.app instead, turn on verbose logging —
either persistently:

```bash
defaults write com.voiceflow.VoiceFlow diagnostics.verboseLogging -bool YES
```

or for one run, with `VOICEFLOW_VERBOSE_LOGGING=1` in the scheme's environment.

```
dictation audio=5.02s whisper=180ms(server) llm=210ms paste=3ms total=396ms
dictation audio=1.14s whisper=90ms(server) llm=skipped paste=2ms total=97ms
```

The backend is `server`, `cli`, or `server+stream`; `llm=skipped` means the transcript
was short and clean enough to bypass the model. Durations, the backend name, and nothing
else — **no transcript text is ever logged**, on any path, at any log level. Verbose
logging is off by default and the release path stays quiet.

Three things bound the cleanup pass, and all three show up in that line: the 3B default
model, a per-request `num_predict` of `max(32, words × 2)` capped by your configured
maximum rather than a flat 512, and not running the model at all when the transcript
does not need it.

---

## Troubleshooting

Run `./scripts/check-setup.sh` first — it diagnoses most of these.

**Nothing happens when I press fn**
Accessibility permission is missing or stale. Check
**System Settings → Privacy & Security → Accessibility**, remove any old VoiceFlow
entry with **−**, and re-add the app you just built. The menu bar shows the current
status, and the tap restarts by itself when you change or re-record the hotkey.

**"Ollama is not running."**
Start it: `ollama serve`, or `brew services start ollama` to run it at login. Confirm
with `curl http://localhost:11434/api/tags`.

**"The model qwen2.5:3b is not installed."**
`ollama pull qwen2.5:3b`, or point Settings → LLM at a model you already have.

**"The whisper.cpp command line tool was not found."**
`brew install whisper-cpp`. If you built it yourself, set the binary path in
**Settings → Speech** — the error message lists every path that was searched, for both
the CLI and the server.

**"The Whisper model is missing at …"**
`./scripts/download-whisper-model.sh base.en`, or pick a model you do have in
**Settings → Speech**. The error carries the exact path it looked for.

**Text appears in the wrong app**
VoiceFlow captures the frontmost app at the moment you press the hotkey. If you switch
apps mid-dictation, the text goes to the app you started in. This is deliberate. Note
that the settings window opens at launch and is an ordinary window — if it is focused
when you press the hotkey, VoiceFlow reports no target app and you get the generic
formatting hint.

**Text doesn't appear, but ⌘V works**
That app blocks synthetic paste. Turn on **Type text instead of pasting** in
**Settings → General**. Slower, but it works in secure fields and some terminals.

**My clipboard was replaced**
The clipboard is restored ~350 ms after pasting, on a background task. If the paste
itself failed, the text is left on the clipboard deliberately so your words aren't
lost — press ⌘V.

**Transcription is slow**
Install `whisper-server` so the weights stay loaded (see [Setup](#2-install-whispercpp)),
use a smaller model, or turn on **Transcribe while I speak** in **Settings → Speech**,
which transcribes each pause as you reach it so only the tail is left at key-up.
Language is already pinned to English by default; if you changed it to auto-detect,
change it back.

**It transcribed something I didn't say**
Whisper hallucinates on silence. VoiceFlow discards recordings under 0.2 s and strips
`[BLANK_AUDIO]`-style annotations, but a noisy room can still produce artefacts. Try a
larger model, or Exact mode.

**A parenthesis went missing**
Bracketed and parenthesised spans are stripped as Whisper non-speech annotations,
unless stripping them would empty the transcript.

---

## Known limitations

These are real and deliberate; none is a crash.

- **Unverified build.** Written without access to a macOS toolchain. See
  [Status](#status).
- **The settings window opens on every launch.** Deliberate, for visual feedback that
  the app started — but it means VoiceFlow takes focus at login if you have enabled
  launch at login.
- **Model reload per dictation, on the CLI backend only.** `whisper-cli` loads weights
  on each invocation, adding a few hundred milliseconds. Installing `whisper-server`
  (or leaving **Settings → Speech → Engine** on Automatic, which prefers it) removes
  this; forcing the CLI backend brings it back.
- **Incremental transcription needs the resident server.** With the CLI backend the
  toggle is disabled: spawning a process per chunk would be slower than doing nothing.
- **Trailing key-up leaks.** If you bind a modifier combination and release the modifier
  before the key, the state machine ends the utterance on the modifier drop and the
  subsequent key-up is no longer consumed. A key-up with no matching key-down is a no-op
  in practice, but it is not swallowed. Covered by
  `testTrailingKeyUpIsNotConsumedOnceRecordingHasEnded`.
- **Clipboard restore is time-based.** 350 ms is a heuristic. An app that reads the
  pasteboard lazily could miss the text; one that reads it slowly could see the restore.
- **Launch at login needs a stable signature.** `SMAppService` registration typically
  fails for an ad-hoc-signed debug build run from DerivedData.
- **One language per dictation.** Whisper's language is a setting, not per-utterance.
- **Five-minute recording cap.** Samples past that are dropped, so a stuck hotkey can't
  grow the buffer without bound.
- **`scripts/check-setup.sh` checks for `qwen3:8b`**, not the app's default
  `qwen2.5:3b`.

---

## Licence

MIT for this project's own code. whisper.cpp, the GGML model weights, Ollama, and any
model you pull each carry their own licences.
