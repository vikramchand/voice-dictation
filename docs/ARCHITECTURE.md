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

### Two whisper.cpp backends behind one protocol

| Approach | Verdict |
|---|---|
| Link `libwhisper` via SPM | Needs a C bridging target and network at build time; ties the project to one whisper.cpp version. Not done. |
| Build whisper.cpp in-tree | The user has to build it; a large source dependency to vendor. Not done. |
| `whisper-cli` subprocess | Simple, debuggable, Metal for free from the bottle. Costs a model load and a Metal init **per dictation**. The fallback. |
| `whisper-server` subprocess | Same binary family, weights stay resident. Costs process lifecycle, port allocation, and orphan cleanup. The default when installed. |

Both live behind `SpeechRecognizer`, and `AdaptiveSpeechRecognizer` picks between them:
it prefers the server, and falls back to the CLI if `whisper-server` is not installed
or does not come up. A user who has only ever had `whisper-cli` sees no change.

The server is started once, at launch, bound to `127.0.0.1` on a port obtained by
binding a socket to port 0 and reading back what the kernel assigned — never a fixed
port, which would collide with the many other things that use 8080 and would let an
unrelated server receive the user's audio.

Its lifecycle is the interesting part:

- **Started** lazily but exactly once. `WhisperServerRecognizer` is an actor, so the
  key-down warmup, the preflight check, and a transcription arriving together await
  one start rather than racing to spawn three servers.
- **Readiness** is "the port accepts a connection": whisper-server binds only after
  the model is loaded, so any HTTP status back means ready.
- **Crash** needs no handler — `supervisor.current` checks `isRunning`, so the next
  transcription finds it gone and relaunches.
- **Clean exit** terminates the child from `applicationWillTerminate`. That path is
  synchronous the whole way down (`SpeechRecognizer.shutdown()` is not `async`)
  because an `async` hop at termination may never be scheduled.
- **Unclean exit** is covered by a pid file. At the next launch the pid is claimed
  *synchronously, before anything starts a server of our own* — otherwise the check
  could not tell last run's leftover from this run's child — and killed only after
  `ps` confirms the pid is still running something called whisper-server. macOS
  recycles pids fast, and signalling a stranger's process is worse than leaking one.

`WhisperCppRecognizer.arguments(...)` and `WhisperServerSupervisor.arguments(...)` are
static pure functions, and so are the multipart encoder and response parser in
`WhisperServerWire`, so the flags and the wire format are asserted in tests rather than
discovered at runtime.

### Starting before the user stops speaking

Nothing in the pipeline needs to wait for key-up to *begin*.

**Warmup at key-down.** Both engines are nudged awake the moment the hotkey goes down:
the speech backend gets a no-op touch (which starts `whisper-server` if it isn't up),
and Ollama gets a request with `num_predict: 0` carrying the exact system prompt the
real request will send, so the model is loaded and the prefix cache is populated. It is
detached, best-effort, and completely invisible — it never blocks recording, never
changes state, and never surfaces an error, because the engines are about to be asked
for real work regardless. `keep_alive: "60m"` already covers the steady state; this
buys back the multi-second penalty on the first dictation after launch or after
eviction. It is cancelled at key-up, where it would only compete with the real request.

**Transcribing while recording** (opt-in, resident backend only). `StreamingTranscriber`
watches the live `AudioBuffer` and hands Whisper each chunk as it becomes safe to cut,
so at key-up only the tail is left.

"Safe to cut" is the whole design. Cutting on a timer splits words across chunk
boundaries, and Whisper will happily invent a plausible word out of half of one — so
`SpeechSegmenter` only ever cuts in the *middle* of a run of silence long enough to be
a real pause, and if the speaker never pauses it returns no boundary at all and the
utterance is transcribed in one piece, exactly as before.

Everything about the path is built to degrade to the old behaviour rather than to a
wrong transcript. A failed chunk, an empty commit, or a sample count that doesn't line
up all make `finish` return nil, and the caller transcribes the whole WAV in one pass.
When it does succeed, the stitched transcript reaches the pipeline wrapped in a
`PrecomputedTranscriptRecognizer`, so `TranscriptionPipeline` never learns that
transcription can finish before the hotkey is released. `AudioBuffer.samples(from:)` is
non-destructive, so the WAV `stop()` writes is still the complete utterance.

The correctness bar is asserted directly: a test transcribes the same synthetic audio
both ways, through a position-independent stand-in recognizer, and requires the stitched
result to equal the one-shot result.

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

The hint goes in the **user** prompt, not the system prompt. Ollama caches the
evaluated prefix of a request, and the system prompt is the whole of that prefix; when
the hint lived there, switching apps — which for a dictation utility is most dictations
— invalidated the cache and paid full prompt evaluation again. The system prompt is now
byte-identical across every app within a mode, and a test asserts it. The mode override
still changes it, because that changes the rules the model is given, which is the point.

### Spending the LLM in proportion to the utterance

Three things bound the cleanup pass:

- **A 3B default.** Cleanup is punctuation, capitalization, and filler removal. A 3B
  does that about as well as a 7B and decodes two to three times faster. An explicitly
  chosen model is never overridden.
- **A per-request budget.** `num_predict` is derived from the transcript
  (`max(32, words × 2)`, capped by the user's configured maximum) instead of a flat 512.
  Cleanup is near length-preserving, so the output is bounded by the input, and the
  runaway generation — a model that starts explaining itself instead of stopping — is
  the single worst latency spike available.
- **Not running it at all.** `CleanupHeuristics.needsModelCleanup` routes short,
  filler-free, disfluency-free transcripts straight to `TextSanitizer.lightweightCleanup`.
  The bar is deliberately high and the predicate errs towards the model: a needless pass
  costs a couple of hundred milliseconds, a wrongly-skipped one leaves "um" in the
  user's document. A skip is not a degraded outcome — nothing failed — so
  `degradedReason` stays nil and the UI still reports success.

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

**Streaming transcription** — partially there. With the resident backend, work starts
before key-up: see "Starting before the user stops speaking" above. What is *not* there
is showing partial text as it arrives; that would need a protocol method returning an
`AsyncSequence` and partial-text rendering in the indicator.

**Per-app modes** — `ApplicationKind.effectiveModeOverride` is the hook. A user-editable
bundle-ID → mode map would replace the hard-coded terminal/editor rule.
