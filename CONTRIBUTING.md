# Contributing to pua

pua is phone-use for AI agents. This is the map for changing or extending it: where things
live, which parts are designed to be swapped, the contracts to keep stable, and how to check a
change without a phone.

How the call path works, with evidence, is in [ANALYSIS.md](ANALYSIS.md) and
[docs/analysis/pua-design.md](docs/analysis/pua-design.md). User settings are in
[docs/configuration.md](docs/configuration.md).

## Layout

| Path | Responsibility |
| --- | --- |
| `Sources/pua/main.swift` | The CLI: argument parsing, one `case` per command, flags over config |
| `Sources/PuaKit/Config.swift` | Config file (`PuaConfig`), lookup (`LoadedConfig`), resolved `ConversationSettings`, default prompts and greetings |
| `Sources/PuaKit/Conversation/Engines.swift` | **Extension points**: `SpeechRecognizer`, `ReplyModel`, `Voice` and the name registry |
| `Sources/PuaKit/Conversation/AppleEngines.swift` | `apple` STT (SpeechTranscriber) and `apple` LLM (Foundation Models) |
| `Sources/PuaKit/Conversation/ElevenLabsSTT.swift` | `elevenlabs` STT: Scribe v3 Live over WebSocket, turn prediction (`predictsTurns`) |
| `Sources/PuaKit/Conversation/Voices.swift` | `system` (macOS voice) and `elevenlabs` TTS |
| `Sources/PuaKit/CallSession.swift` | `CallSession`: what runs on a connected call (pua's `Conversation` or a `MediaStreamBridge`), and the per-call factories |
| `Sources/PuaKit/Conversation/ExecModel.swift` | `exec` LLM: your agent process, JSON lines (docs/integration.md) |
| `Sources/PuaKit/MediaStream.swift` | `--stream`: Twilio Media Streams compatible WebSocket bridge, μ-law, resampling |
| `Sources/PuaKit/Conversation/Conversation.swift` | Turn-taking on a connected call: half duplex, end of turn, latency, `[hangup]` |
| `Sources/PuaKit/Conversation/Recording.swift` | WAV, transcripts, `call.json` |
| `Sources/PuaKit/Listen.swift` | `pua listen`: ring, delay, route, answer, run the session, restore, repeat |
| `Sources/PuaKit/Hooks.swift` | Runs `hooks.*` commands |
| `Sources/PuaKit/CallControl.swift` | Call state and buttons through Accessibility; callservicesd log watch |
| `Sources/PuaKit/PhoneRoute.swift` | Phone app *Audio* menu: point the microphone at PUA Call Mic and back |
| `Sources/PuaKit/Dialer.swift` | Dialing through the "PUA Dial" Shortcut |
| `Sources/PuaKit/ProcessTap.swift`, `DeviceFeed.swift` | Hearing the caller (process tap) and speaking into the call (PUA Call Feed) |
| `Sources/PuaKit/AudioStream.swift` | `audio-stream`: raw PCM in and out for external agents |
| `Driver/PuaCallMic.c` | The HAL driver: `PUA Call Mic` (input) and `PUA Call Feed` (output) on one ring |
| `skills/phone-use/SKILL.md` | The phone-use skill for agent harnesses (canonical copy) |
| `Sources/PuaKit/Skill.swift`, `SkillText.swift` | `pua skill install`; `SkillText.swift` is generated from SKILL.md by `scripts/embed-skill.sh` |
| `Tests/PuaKitTests` | Offline tests (`swift test`) |
| `examples/` | A config, a prompt file, a hook script, and example agents for `--exec` and `--stream` |

## How a conversation runs

```
caller ─▶ avconferenced ─tap─▶ Conversation ─▶ SpeechRecognizer.append (48 kHz Float32, 20 ms)
                                    │                    │ results (text, isFinal, end)
                                    │◀───────────────────┘
                                    │ end of turn (silence)
                                    ├─▶ ReplyModel.reply(to:) ─ text pieces ─▶ sentences
                                    └─▶ Voice.speak(sentence, to: SpeechOutput) ─▶ PUA Call Feed ─▶ caller
```

`converse`, `stream` and `listen` differ only in how the call starts: `converse` and `stream`
dial (or join a connected call), `listen` waits for one to ring and answers it. Each makes one
`CallSession` per call through a `CallSessionFactory`, before the call connects: a
`Conversation` with a fresh, prepared `EngineSet`, or a `MediaStreamBridge` to `--stream`. A
session that never runs gets `discard()`, so an `exec` agent always receives `call_end`.

## Add an engine

An engine is one class plus one line. Example: a reply model served by a local HTTP server.

1. Create `Sources/PuaKit/Conversation/MyModel.swift` and implement the protocol:

   ```swift
   public final class MyModel: ReplyModel, @unchecked Sendable {
       public let name = "mymodel"
       private let instructions: String
       private var history: [[String: String]] = []

       public init(settings: ConversationSettings) { instructions = settings.instructions }

       public func prepare() async throws { /* check the server is up; throw PuaError if not */ }

       public func reply(to callerText: String) -> AsyncThrowingStream<String, Error> {
           AsyncThrowingStream { continuation in
               let task = Task {
                   // Stream tokens from your API and yield each piece as it arrives:
                   // continuation.yield(piece)
                   continuation.finish()
               }
               continuation.onTermination = { _ in task.cancel() }
           }
       }
   }
   ```

2. Register it in `Engines` (`Engines.swift`):

   ```swift
   public static let models: [String: Factory<ReplyModel>] = [
       "apple": { AppleReplyModel(instructions: $0.instructions) },
       "mymodel": { MyModel(settings: $0) },
   ]
   ```

3. Select it with `"engines": { "llm": "mymodel" }` or `--llm mymodel`. `pua config show`
   lists it under `engines_available`.

The contracts, which `Conversation` relies on:

| Protocol | Must |
| --- | --- |
| `SpeechRecognizer` | Accept 48 kHz mono Float32 in `append` from the audio thread and return quickly. Report `end` in seconds of appended audio. Send partial results for a phrase, then one final result. End `results` on `finish()`, which may be called more than once. If it knows when the caller is done, set `predictsTurns` and mark that final result `endOfTurn`: pua then answers right away instead of waiting for silence. |
| `ReplyModel` | Keep the context for one call (a new instance is made per call). Use `settings.instructions`, which already contains pua's call rules. Yield text in order; pua finds the sentences. Throw on failure: pua says a short fallback line. |
| `Voice` | Write 48 kHz mono Float32 to `SpeechOutput` while synthesizing, so the first audio goes out before the sentence is finished. Throw on failure: pua repeats the sentence with the macOS voice. |

Read secrets from the environment in the engine's initializer, never from the config file.
Engine settings that need a new config key follow the next section.

## Add a config key

1. Add the field to the matching struct in `PuaConfig` (`Config.swift`). JSON keys are the
   snake_case form of the Swift name.
2. Add it to `PuaConfig.knownKeys`. `swift test` fails if the two drift apart.
3. Apply it in `LoadedConfig.conversationSettings` (or the `listen` accessors), and add a flag in
   `conversationSettings(_:_:_:)` in `main.swift` if it should be overridable.
4. Document it in the key table in [docs/configuration.md](docs/configuration.md).

Keys are additive. If a change has to break existing files, raise `version` and keep reading
the old form.

## Extend without Swift

* **Agents.** `--exec CMD` (text in, text out) or `--stream URL` (a voice agent speaking
  Twilio Media Streams). See [docs/integration.md](docs/integration.md).
* **Hooks.** `hooks.call_ended` gets every call's summary and transcript as JSON on stdin.
  Summaries, message delivery and logging can live there. See
  [docs/configuration.md](docs/configuration.md#hooks).
* **Events.** `converse` and `listen` write JSON lines on stderr, so a supervisor can react to
  `ringing`, `heard`, `said` and `call_finished` live.
* **Raw audio.** `pua audio-stream` hands the call to any program as PCM16 on stdin and stdout.
* **Other languages for call buttons.** `PUA_ANSWER_LABELS`, `PUA_DECLINE_LABELS` and
  `PUA_END_LABELS` (comma-separated) add button labels for other macOS languages.

## Contracts to keep stable

| Contract | Where |
| --- | --- |
| stdout: one JSON object per command; stderr: JSON lines with `event` and `t` | `Events` in `PCM.swift`; event list in docs/configuration.md |
| Call audio: PCM16 little-endian, 48 kHz, mono | `audio-stream`, `SpeechOutput` |
| Config keys and their meaning | `PuaConfig`, docs/configuration.md |
| Recording files and transcript fields | `Recording.swift` |
| The `[hangup]` marker and the call rules | `Conversation.callRules` |
| The `exec` agent protocol (message types and fields) | `ExecModel.swift`, docs/integration.md |
| The stream message set, μ-law 8 kHz, mark and clear semantics | `MediaStream.swift`, docs/integration.md |
| Commands, flags, JSON fields and error codes the phone-use skill relies on | `skills/phone-use/SKILL.md` |

## Check a change

Start with the cheapest check that covers your change.

| Change | Check |
| --- | --- |
| Config, prompts, splitting | `swift test` |
| The phone-use skill | Edit `skills/phone-use/SKILL.md`, run `make` (or `scripts/embed-skill.sh`), then `swift test` |
| Audio path or driver | `pua selftest` (no call needed) |
| A conversation engine, or the `exec` protocol | `swift test`, then the offline conversation below with `--exec` |
| The stream bridge | The offline conversation below with `pua stream` and `examples/agents/stream_echo.py` |
| Dialing, answering, routing | One real call |

An offline conversation plays a scripted caller with `afplay`. pua taps that process instead of
the call, so no phone is involved:

```sh
say -o /tmp/caller.aiff "[[slnc 8000]] Hi, can you tell me a fun fact? [[slnc 11000]] Thanks, goodbye."
afplay /tmp/caller.aiff & pid=$!
.build/debug/pua converse --pid $pid --no-call-guard --no-hangup --no-greeting --record /tmp/pua-test
kill $pid
```

The summary on stdout should show the caller's turns, the agent's replies and
`"reason": "agent_hung_up"` after the goodbye.

## Conventions

* [Conventional Commits](https://www.conventionalcommits.org) (`feat(listen): …`,
  `fix(route): …`, `docs: …`).
* Bump `version` in `Sources/pua/main.swift` with each user-visible change.
* No third-party dependencies so far; keep it that way unless the gain is large.
* Keep personal data (names, numbers, recordings of real people) out of the repository,
  including tests and docs.
