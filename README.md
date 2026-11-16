# pua

Tunnel your iPhone's cellular calls through your Mac to a program or AI agent: dial, answer,
hang up, hear the caller and speak into the call. It is built on Apple Continuity
("Calls on Other Devices") and the macOS Phone app. Nothing runs on the iPhone.

How and why it works this way: [ANALYSIS.md](ANALYSIS.md) (the mechanism, with evidence) and
[docs/analysis/pua-design.md](docs/analysis/pua-design.md) (design and verification).

```
iPhone ─Continuity─▶ avconferenced ──process tap (muted)──▶ pua stdout  (PCM16 48k mono: caller)
                      Phone.app mic ◀── PUA Call Mic ◀ PUA Call Feed ◀── pua stdin (PCM16 48k mono: you/agent)
```

## Demo: a phone conversation with an AI

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

- macOS 26 or later (Phone app), Apple Silicon or Intel. `converse` also needs Apple Intelligence
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

### AI conversation

```sh
# Dial, talk, record. With ELEVENLABS_API_KEY set the agent uses ElevenLabs; otherwise the macOS voice.
pua converse --dial "+1 555 123 4567" --record ./call
pua converse --route --record ./call                    # on a call that is already connected
pua converse --route --instructions-file persona.txt --greeting "Hi, this is an AI assistant…"
```

`converse` is half duplex: it listens until the caller has been quiet for 0.8 s
(`--end-silence`), replies, and ignores what is said while it speaks. The model ends the call
when the caller says goodbye (`--no-hangup` keeps it up). `--record DIR` writes
`conversation.wav` (stereo: left caller, right agent), `transcript.md` and `transcript.jsonl`.
Events (stderr JSONL): `conversation_ready`, `heard`, `said` (with `latency_s`), `hung_up`,
`llm_error`, `tts_error`. Other flags: `--tts system|elevenlabs`, `--voice ID`,
`--tts-model ID` (default `eleven_flash_v2_5`), `--max-seconds N` (default 300).

## Safety

`pua` acts only on explicit commands and never auto-answers. It records audio only with
`converse --record`, and the default greeting tells the caller they are talking to an AI and
that the call is recorded. Keep that disclosure when you change the greeting, and follow your
local call-recording laws. Speech recognition and the language model run on the Mac. With
ElevenLabs TTS, only the agent's reply text is sent to ElevenLabs.

## Status

See [docs/analysis/pua-design.md](docs/analysis/pua-design.md) for what was verified on hardware
and the known gaps. Uninstall the driver with `sudo scripts/uninstall-driver.sh`.
