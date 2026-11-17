# Command reference

Every command prints JSON on stdout and progress events as JSON lines on stderr.
`pua help` prints the full list of commands and flags.

## Setup

```sh
make                                                    # CLI + driver (ad-hoc signed)
make driver SIGN_IDENTITY="Developer ID Application"    # recommended: sign the driver with your identity
sudo scripts/install-driver.sh                          # installs PUA Call Mic + PUA Call Feed, restarts coreaudiod
pua permissions                                         # Accessibility for this terminal
pua shortcut install                                    # build, sign and import "PUA Dial" (AX presses Add Shortcut)
pua doctor                                              # every prerequisite with its next action
pua selftest                                            # proves both audio legs without a call
```

Permissions attach to the app that runs `pua` (your terminal or agent):

| Permission | Why |
| --- | --- |
| Accessibility | Call buttons and the Phone Audio menu |
| System Audio Recording | Process tap |
| Microphone | Only for `selftest`, which reads back the virtual mic |

Requirements in detail:

* **macOS:** 26 or later (Phone app), Apple Silicon or Intel. The built-in agent needs Apple
  Intelligence turned on (Apple Silicon); its English speech model downloads on first use.
* **iPhone:** on the same Apple Account and Wi-Fi, with *Settings > Apps > Phone > Calls on
  Other Devices > (this Mac)* turned on.
* **FaceTime:** the phone number must be enabled in FaceTime on the Mac.

Uninstall the driver with `sudo scripts/uninstall-driver.sh`.

## Skill for agent harnesses

```sh
pua skill install [--dir DIR]     # copy the phone-use skill into ~/.claude/skills and ~/.agents/skills (or DIR)
pua skill uninstall [--dir DIR]   # remove copies that pua installed
pua skill show                    # print the skill
```

The installed copy ends with this pua's path and version. Run `pua skill install` again after
moving or updating pua.

## Calls

```sh
pua call dial "+1 555 0100"            # via the PUA Dial shortcut (first run: allow the Call action)
pua call state --watch                 # idle | incoming | active, with caller and timer
pua call answer --wait 30              # wait for a ringing call and accept it
pua call hangup
pua route status | setup | restore     # point the Phone microphone at PUA Call Mic, and back
```

## Built-in agent

```sh
# Outgoing: dial, talk, record. With ELEVENLABS_API_KEY set the agent uses ElevenLabs; otherwise the macOS voice.
pua converse --dial "+1 555 0100" --record ./call
pua converse --route --record ./call                    # on a call that is already connected

# Incoming: answer every call that rings for 8 s, take a message, record it. Ctrl-C stops.
pua listen --answer-after 8 --record ~/pua-calls
pua listen --config examples/receptionist.json          # persona, prompt file, hook from a config file
pua config show                                         # the settings in effect, and where they came from
```

* **Turn-taking:** both commands are half duplex. The agent listens until the caller has been
  quiet for 0.8 s (`--end-silence`), replies, and ignores what is said while it speaks. It hangs
  up after the caller says goodbye (`--no-hangup` keeps the call up).
* **Recording:** `--record DIR` writes `conversation.wav` (stereo: left caller, right agent),
  `transcript.md`, `transcript.jsonl` and `call.json`.
* **How `listen` answers:** one call at a time. While a call rings, it waits `--answer-after`
  seconds so you can still pick up on the iPhone or the Mac. Then it points the Phone microphone
  at PUA Call Mic and presses Accept. The microphone goes back to normal after every call.
  `--once` or `--max-calls N` end it after N calls.
* **Settings:** the system prompt, greeting, voice, engines, timing, recording folder and an
  after-call hook come from a JSON config file, with flags on top. See
  [configuration.md](configuration.md).

## Your agent

Add `--exec CMD` (a text agent) or `--stream URL` (a voice agent) to `converse` or `listen`, or
run `pua stream URL`. The protocols are in [integration.md](integration.md).

## Raw audio

```sh
# Duplex audio. --route sets the Phone microphone to PUA Call Mic and restores it on exit.
pua audio-stream --route < agent-speech.pcm > caller.pcm
```

Audio is PCM16 little-endian, 48 kHz mono, both ways. Example with macOS speech:

```sh
say -o /tmp/hi.aiff "Hello, this is an assistant calling for Alex."
ffmpeg -loglevel error -i /tmp/hi.aiff -f s16le -ar 48000 -ac 1 - \
  | pua audio-stream --route --stop-after-playback > caller.pcm
```

Events (stderr JSONL): `ready`, `route`, `stats` (every 5 s), `playback_eof`,
`playback_drained`, `call_ended`, `route_restored`, `stopped`.

Flags:

* `--monitor` keeps the caller audible on your speakers.
* `--max-seconds N` bounds the session.
* `--process` or `--pid` override the tapped process (default `com.apple.avconferenced`).
* `--capture-only` and `--playback-only` run one direction.
* `--no-call-guard` skips stopping when the call ends.

Stopping `audio-stream` never hangs up the call.

## Diagnostics

* `pua doctor`: each prerequisite, with its next action.
* `pua selftest`: proves both audio legs without a call.
* `pua devices` and `pua processes`: Core Audio devices and the processes playing audio.
* `pua ui-dump`: the call window's buttons and labels, for calibrating during a live call.

The events of `converse`, `stream` and `listen` are listed in
[configuration.md](configuration.md#events).
