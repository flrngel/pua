# pua

Put your own agent on your iPhone's phone calls, from a Mac. pua handles the phone side:
dialing, answering, hanging up, getting audio in and out of the call, recording, and hooks. Your
agent does the talking, as a text agent over JSON lines, a voice agent over a
Twilio-compatible WebSocket, or a program reading raw audio. A built-in on-device agent covers
basic use. pua is built on Apple Continuity ("Calls on Other Devices") and the macOS Phone app.
Nothing runs on the iPhone.

How and why it works this way: [ANALYSIS.md](ANALYSIS.md) (the mechanism, with evidence) and
[docs/analysis/pua-design.md](docs/analysis/pua-design.md) (design and verification).

```
iPhone ─Continuity─▶ avconferenced ──process tap (muted)──▶ pua stdout  (PCM16 48k mono: caller)
                      Phone.app mic ◀── PUA Call Mic ◀ PUA Call Feed ◀── pua stdin (PCM16 48k mono: you/agent)
```

## Attach your agent

| Your agent | Flag | It gets |
| --- | --- | --- |
| Text in, text out (an LLM harness, a tool-using agent) | `--exec CMD` | Each caller turn as text, one process per call. pua does speech recognition, voice and turn-taking. |
| A voice agent (speech-to-speech, a bot built for Twilio) | `--stream URL` | The call as Twilio Media Streams messages: μ-law audio, `mark` and `clear` for interruptions |
| Any program | `pua audio-stream` | PCM16 48 kHz on stdin and stdout, plus `pua call …` for control |

```sh
pua listen --answer-after 8 --exec "python3 examples/agents/clock_agent.py"   # answer incoming calls
pua converse --dial "+1 555 0100" --exec "python3 my_agent.py"               # place a call
pua stream ws://127.0.0.1:8765 --dial "+1 555 0100"                          # a voice agent on the call
```

[docs/integration.md](docs/integration.md) has both protocols, the example agents in
[examples/agents](examples/agents), and notes for Pipecat. Without `--exec` or `--stream`, pua
uses its built-in agent (below).

## Demo: the built-in agent on a call

A live call from the Mac to an iPhone, recorded with `pua converse --dial … --record`
(2026-11-16, 87 s). Jessica hears the caller with Apple's on-device speech recognition, thinks
with Apple's on-device Foundation Models, and speaks with ElevenLabs Flash v2.5.

<audio controls src="docs/demo/conversation.m4a"></audio>

[▶ Listen to the recording (m4a, 87 s)](docs/demo/conversation.m4a)

```
caller ─▶ avconferenced ─tap─▶ SpeechTranscriber ─▶ Foundation Models ─▶ ElevenLabs TTS ─▶ PUA Call Feed ─▶ caller
          (iPhone call)        (on-device)          (on-device)          (or macOS voice)
```

| Time | Speaker | What was said (as recognized) |
| --- | --- | --- |
| 0:00 | Jessica (AI) | Hi, it's Jessica, the AI assistant calling from your Mac through pua. Just so you know, this call is being recorded for a demo. How's your day going? |
| 0:10 | Caller | _"Good. How are you?"_ (missed: the reply came the instant the greeting ended; fixed in 0.3.1) |
| 0:24 | Caller | Are you still |
| 0:27 | Jessica (AI) | Hi there! I'm right here with you, ready to chat. How's your day going? |
| 0:32 | Caller | Good. How are you? But I will ask you again. |
| 0:38 | Jessica (AI) | I'm doing great, thanks for asking! What’s on your mind today? |
| 0:43 | Caller | Well, what is my name? |
| 0:47 | Jessica (AI) | I don’t have a name, but I’m here to help—what’s your favorite thing to do when you’re relaxing? |
| 0:53 | Caller | Oh, and I'm relaxing. I just want to um Take |
| 1:00 | Jessica (AI) | That sounds lovely—how are you finding this quiet time? |
| 1:04 | Caller | I mean, like, I, I just have a quite time during, like, like, 30 minutes before I get to that. So. |
| 1:14 | Jessica (AI) | I totally get that—what kind of things do you usually think about during those quiet moments? |
| 1:20 | Caller | _"I don't know."_ (hung up) |

Measured in the recording, from the end of the caller's speech to Jessica's first audio:
2.1 to 3.1 s, median 2.8 s. That gap is the 0.8 s end-of-turn wait, the on-device model's first
sentence, and the first TTS audio. Replies are streamed sentence by sentence. The small on-device
model is chatty but shallow: it took "what is my name?" as a question about itself.

## Requirements

- macOS 26 or later (Phone app), Apple Silicon or Intel. `converse` and `listen` also need Apple Intelligence
  turned on (Apple Silicon); its English speech model downloads on first use.
- An iPhone on the same Apple Account and Wi-Fi, with *Settings > Apps > Phone > Calls on Other
  Devices > (this Mac)* enabled. FaceTime on the Mac must have the phone number enabled.
- Xcode command line tools to build.

## Setup

```sh
make                                                    # CLI + driver (ad-hoc signed)
make driver SIGN_IDENTITY="Developer ID Application"    # recommended: sign the driver with your identity
sudo scripts/install-driver.sh                          # installs PUA Call Mic + PUA Call Feed, restarts coreaudiod
.build/release/pua permissions                          # Accessibility for this terminal
.build/release/pua shortcut install                     # build, sign and import "PUA Dial" (AX presses Add Shortcut)
.build/release/pua doctor                               # every prerequisite with its next action
.build/release/pua selftest                             # proves both audio legs without a call
```

Permissions attach to the app that runs `pua` (your terminal or agent):

| Permission | Why |
| --- | --- |
| Accessibility | Call buttons and the Phone Audio menu |
| System Audio Recording | Process tap |
| Microphone | Only for `selftest`, which reads back the virtual mic |

## Use

```sh
pua call dial "+1 555 123 4567"        # via the PUA Dial shortcut (first run: allow the Call action)
pua call state --watch                 # idle | incoming | active, with caller and timer
pua call answer --wait 30              # wait for a ringing call and accept it
pua call hangup

# Duplex audio. --route sets the Phone microphone to PUA Call Mic and restores it on exit.
pua audio-stream --route < agent-speech.pcm > caller.pcm
```

Example with macOS speech:

```sh
say -o /tmp/hi.aiff "Hello, this is an assistant calling for Alex."
ffmpeg -loglevel error -i /tmp/hi.aiff -f s16le -ar 48000 -ac 1 - \
  | pua audio-stream --route --stop-after-playback > caller.pcm
```

`audio-stream` events (stderr JSONL): `ready`, `route`, `stats` (every 5 s), `playback_eof`,
`playback_drained`, `call_ended`, `route_restored`, `stopped`.

Flags:

- `--monitor` keeps the caller audible on your speakers.
- `--max-seconds N` bounds the session.
- `--process` or `--pid` override the tapped process (default `com.apple.avconferenced`).
- `--capture-only` and `--playback-only` run one direction.
- `--no-call-guard` skips stopping when the call ends.

Stopping `audio-stream` never hangs up the call.

### Built-in agent

```sh
# Outgoing: dial, talk, record. With ELEVENLABS_API_KEY set the agent uses ElevenLabs; otherwise the macOS voice.
pua converse --dial "+1 555 123 4567" --record ./call
pua converse --route --record ./call                    # on a call that is already connected

# Incoming: answer every call that rings for 8 s, take a message, record it. Ctrl-C stops.
pua listen --answer-after 8 --record ~/pua-calls
pua listen --config examples/receptionist.json          # persona, prompt file, hook from a config file
pua config show                                         # the settings in effect, and where they came from
```

Both are half duplex: the agent listens until the caller has been quiet for 0.8 s
(`--end-silence`), replies, and ignores what is said while it speaks. It hangs up after the
caller says goodbye (`--no-hangup` keeps the call up). `--record DIR` writes
`conversation.wav` (stereo: left caller, right agent), `transcript.md`, `transcript.jsonl` and
`call.json`.

`listen` answers one call at a time. While a call rings it waits `--answer-after` seconds, so
you can still pick up on the iPhone or the Mac, then points the Phone microphone at PUA Call Mic
and presses Accept. The microphone goes back to normal after every call. `--once` or
`--max-calls N` end it after N calls.

The system prompt, greeting, voice, engines, timing, recording folder and an after-call hook
come from a JSON config file, with flags on top: see [docs/configuration.md](docs/configuration.md).
Events go to stderr as JSON lines (`ringing`, `answered`, `heard`, `said`, `call_finished`, …).

## Safety

`pua` acts only on explicit commands. It answers calls only while `pua listen` runs, and records
audio only with `--record` (or `record.directory`). Call audio goes only where you point it: an
`--exec` agent gets text, a `--stream` server gets the audio. The default greetings tell the caller they are
talking to an AI, and that the call is recorded when it is. Keep that disclosure when you change the greeting, and follow your
local call-recording laws. Speech recognition and the language model run on the Mac. With
ElevenLabs TTS, only the agent's reply text is sent to ElevenLabs.

## Status

See [docs/analysis/pua-design.md](docs/analysis/pua-design.md) for what was verified on hardware
and the known gaps. Uninstall the driver with `sudo scripts/uninstall-driver.sh`.

## Extending

Agents attach without Swift: see [docs/integration.md](docs/integration.md). Inside pua, speech
recognition, the reply model and the voice are pluggable engines selected by name in the
config. [CONTRIBUTING.md](CONTRIBUTING.md) maps the code, shows how to add an engine or a config
key, and lists the checks that need no phone (`swift test`, `pua selftest`, an offline
conversation).
