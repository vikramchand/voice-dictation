# Architecture

Why the pieces are shaped the way they are. For setup and usage see
[../README.md](../README.md).

## The flow

```
                 ⌥Space down
                      │
      ┌───────────────▼────────────────┐
      │ GlobalHotkeyManager (CGEventTap)│  main run loop, returns immediately
      └───────────────┬────────────────┘
                      │ beginRecording
      ┌───────────────▼────────────────┐
      │ DictationCoordinator (@MainActor)│
      │   captures frontmost app NOW    │  ← before any VoiceFlow UI appears
      └───────────────┬────────────────┘
                      │
      ┌───────────────▼────────────────┐
      │ AudioRecorder (actor)           │
      │   AVAudioEngine tap →           │
      │   AVAudioConverter → 16 kHz mono│  audio render thread
      │   → AudioBuffer (NSLock)        │
      └───────────────┬────────────────┘
                 ⌥Space up
                      │ stop() → WAV in NSTemporaryDirectory
      ┌───────────────▼────────────────┐
      │ TranscriptionPipeline (actor)   │
      │  1. SpeechRecognizer.transcribe │  whisper-cli subprocess
      │  2. LLMProvider.generate        │  POST localhost:11434/api/generate
      │  3. TextInserting.insertText    │  clipboard + synthetic ⌘V
      │     defer { delete the WAV }    │
      └───────────────┬────────────────┘
                      │ PipelineResult
              back to the coordinator
              → menu bar icon, floating indicator
```

## Threading

| Runs on | What |
|---|---|
| Main actor | `DictationCoordinator`, `MenuBarController`, `RecordingIndicatorController`, all SwiftUI |
| Main run loop, non-isolated | The `CGEventTap` callback. Updates the state machine and defers everything else — a slow tap callback gets the tap **disabled** by the system. |
| Audio render thread | The `AVAudioEngine` tap block. Touches only the converter and `AudioBuffer`. No allocation beyond the sample append, no locks held across I/O. |
| Cooperative pool | `AudioRecorder` and `TranscriptionPipeline` actors, `URLSession`, `Process` waits. |

Nothing expensive ever runs on the main thread. The two actors serialize their own
state, so overlapping hotkey presses queue rather than race.

`AudioBuffer` is an `NSLock`-guarded class rather than an actor on purpose: the audio
render thread cannot `await`.

## Design decisions

### `CGEventTap` rather than `RegisterEventHotKey`

Push-to-talk needs the key-down edge, the key-up edge, *and* modifier-release. Carbon
hot keys are awkward for the third, and cannot swallow the event — ⌥Space would insert
a non-breaking space into the document you are dictating into. An event tap gives all
three, and Accessibility permission is already required for pasting, so it costs
nothing extra.

The tap is a `.defaultTap` at `.cgSessionEventTap` so it can return `nil` to consume an
event. Only the bound key is ever consumed; modifier events always pass through, or
every other shortcut on the system would break.

### Modifier release ends the utterance

Releasing ⌥ before Space is as common as the other order. If only `keyUp` ended
recording, that ordering would strand the recorder with the engine running. So a
`flagsChanged` that drops a required modifier ends the utterance too. The consequence
is documented in the README's known limitations.

### The state machine is a separate value type

`HotkeyStateMachine` is a `struct` over framework-free events. All the ordering rules —
auto-repeat suppression, release ordering, consumption — are covered by unit tests with
no event tap, no window server, and no permissions.

### `whisper-cli` as a subprocess

Alternatives considered:

| Approach | Why not (for the MVP) |
|---|---|
| Link `libwhisper` via SPM | Needs a C bridging target and network at build time; ties the project to one whisper.cpp version. |
| Build whisper.cpp in-tree | The user has to build it; a large source dependency to vendor. |
| `whisper-server` subprocess | Keeps weights resident (faster), but adds process lifecycle, port allocation, and orphan cleanup. |

The CLI is the simplest thing that works, gets Metal for free from the Homebrew bottle,
and is trivially debuggable — you can run the exact command the app runs.

Its cost is a model load per dictation. `SpeechRecognizer` exists so that becomes a
swap rather than a rewrite. `WhisperCppRecognizer.arguments(...)` is a static pure
function so the flags are asserted in tests rather than discovered at runtime.

### `PipelineConfiguration` snapshots

`AppSettings` is an `ObservableObject` that SwiftUI mutates. The pipeline never reads
it. At the moment the hotkey is released, `settings.snapshot()` produces an immutable
`PipelineConfiguration` value, and the whole dictation runs off that. Changing the
model mid-dictation cannot alter a run already in flight, and the pipeline needs no
locking around settings.

### Degraded operation over data loss

If Ollama is down, the user has *already spoken*. Throwing away their words is worse
than inserting a lightly-cleaned transcript, so by default the pipeline falls back to
`TextSanitizer.lightweightCleanup` (capitalize, terminate — no filler removal, since
that needs real context) and reports the failure through `PipelineResult.degradedReason`.
The text lands; the menu bar explains what happened. Switchable in Settings.

The same reasoning covers a model that returns nothing usable — an empty response after
sanitizing falls back to the transcript rather than pasting nothing.

### Sanitizing is deterministic, not prompted

Local instruct models add reasoning blocks, code fences, "Here's the cleaned text:"
preambles, and wrapping quotes even when told not to. Asking more nicely is unreliable;
`TextSanitizer` strips them in code. Each rule is narrow enough not to damage real
dictation — a wholly-fenced response is unwrapped but an interior fence is kept, and
surrounding quotes are removed only when there are no interior quotes.

### Prompt injection from your own voice

A transcript can contain something that reads like an instruction ("ignore the previous
instructions and…"). The transcript is delimited in `<transcript>` tags and the system
prompt states it is text to edit, not a request. This is a correctness measure — the
model's output is pasted into the user's document, so it should stay an edit of what
was said.

### Application context

`ApplicationKind` maps bundle IDs to coarse buckets. It does two things: adds a short
formatting hint, and lets terminals and code editors force `.exact` regardless of the
selected mode. That is the whole feature — deliberately not an app-specific rules
engine.

The frontmost app is captured at key-down, before the indicator appears. The indicator
is a `.nonactivatingPanel` that ignores mouse events and can never become key, so
showing it cannot change which app is frontmost.

### Clipboard preservation

`snapshotClipboard()` captures every representation of every pasteboard item, not just
the plain string, so restoring gives back styled text, images, and file URLs intact.
The restore is delayed ~350 ms because the target app reads the pasteboard
asynchronously.

The synthetic ⌘V uses a `.privateState` event source rather than
`.combinedSessionState`: if the user is still physically holding ⌥, a combined-state
event would arrive as ⌥⌘V and do nothing.

On failure the text is left on the clipboard on purpose, and the error says so.

## Extension points

**Another LLM backend** — implement `LLMProvider` (two methods) and change the factory
closure on `DictationCoordinator`. MLX, Apple Foundation Models, and llama.cpp's server
all fit. Nothing above `LLMProvider` mentions Ollama.

**Another speech engine** — implement `SpeechRecognizer` (`transcribe` + `preflight`).
An in-process whisper.cpp binding, MLX Whisper, or `SFSpeechRecognizer` all fit.

**Streaming transcription** — the pipeline is currently one-shot. Streaming would mean a
new protocol method returning an `AsyncSequence`; the coordinator's state machine
already models discrete stages, so the indicator would need partial-text rendering.

**Per-app modes** — `ApplicationKind.effectiveModeOverride` is the hook. A user-editable
bundle-ID → mode map would replace the hard-coded terminal/editor rule.
