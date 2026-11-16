# pua

Tunnel your iPhone's cellular calls through your Mac to a program or AI agent: dial, answer,
hang up, hear the caller and speak into the call. It is built on Apple Continuity
("Calls on Other Devices") and the macOS Phone app. Nothing runs on the iPhone.

How and why it works this way: [ANALYSIS.md](ANALYSIS.md) (the mechanism, with evidence) and
[docs/analysis/pua-design.md](docs/analysis/pua-design.md) (design and verification).

```
iPhone ─Continuity─▶ avconferenced ──process tap (muted)──▶ pua stdout  (PCM16 48k mono: caller)
                      Phone.app mic ◀── PUA Call Mic ◀──────  pua stdin   (PCM16 48k mono: you/agent)
```

## Requirements

- macOS 26 or later (Phone app), Apple Silicon or Intel. The audio APIs need macOS 14.2 or later.
- An iPhone on the same Apple Account and Wi-Fi, with *Settings > Apps > Phone > Calls on Other
  Devices > (this Mac)* enabled. FaceTime on the Mac must have the phone number enabled.
- Xcode command line tools to build.

## Setup

```sh
make                                                    # CLI + driver (ad-hoc signed)
make driver SIGN_IDENTITY="Developer ID Application"    # recommended: sign the driver with your identity
sudo scripts/install-driver.sh                          # installs PUA Call Mic, restarts coreaudiod
.build/release/pua permissions                          # Accessibility for this terminal
.build/release/pua shortcut install                     # import "PUA Dial" into Shortcuts
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

## Safety

`pua` acts only on explicit commands. It never auto-answers, and it does not record or store
audio. Tell the other party when an AI or a recording is involved, and follow your local
call-recording laws.

## Status

See [docs/analysis/pua-design.md](docs/analysis/pua-design.md) for what was verified on hardware
and the known gaps. Uninstall the driver with `sudo scripts/uninstall-driver.sh`.
