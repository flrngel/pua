# pua: Mac and iPhone call tunneling design

`pua` tunnels iPhone calls through the Mac as an open, single-binary CLI plus one HAL driver.
The mechanism and its evidence are in [ANALYSIS.md](../../ANALYSIS.md). Android is analyzed in
[android.md](android.md) but not implemented; Windows is out of scope.

## Components

| Piece | File |
| --- | --- |
| AudioServerPlugIn with two devices on one clock and ring (48 kHz mono Float32, 16384 frames, cleared on read): input-only `PUA Call Mic` and output-only `PUA Call Feed` | `Driver/PuaCallMic.c` |
| Downlink capture: private, **muted** process tap on `avconferenced`, plus a private aggregate and an IOProc | `Sources/PuaKit/ProcessTap.swift` |
| Uplink feed: AUHAL output unit, `CurrentDevice` = `PUA Call Feed`, render callback | `Sources/PuaKit/DeviceFeed.swift` |
| Duplex session: stdin PCM16 to the caller, stdout PCM16 from the caller, stderr JSONL, call guard | `Sources/PuaKit/AudioStream.swift` |
| AI conversation: tap → `SpeechRecognizer` → `ReplyModel` (streamed by sentence) → `Voice` → `PUA Call Feed`; half duplex, `[hangup]` marker, stereo WAV + transcript recorder fed from the tap and the feed's render monitor | `Sources/PuaKit/Conversation/Conversation.swift`, `Recording.swift` |
| Engines, chosen by name: `apple` STT (`SpeechTranscriber`, on-device), `apple` LLM (Foundation Models, on-device), `system` (`AVSpeechSynthesizer`) and `elevenlabs` (streaming PCM) voices | `Sources/PuaKit/Conversation/Engines.swift`, `AppleEngines.swift`, `Voices.swift` |
| Incoming calls (`listen`): ring → optional delay → prepare engines and route the mic while ringing → AX Accept → connected (AX or callservicesd) → conversation → restore the mic → hook | `Sources/PuaKit/Listen.swift`, `Hooks.swift` |
| Config file and resolved settings (lookup, typo warnings, per-direction default prompts) | `Sources/PuaKit/Config.swift` |
| Call UI: state, answer, decline and hang up through AX | `Sources/PuaKit/CallControl.swift` |
| Phone *Audio* menu route with a journal: activate Phone, open the menu, press, verify, restore | `Sources/PuaKit/PhoneRoute.swift` |
| Dial: generate and sign the "PUA Dial" Shortcut, run it with `--input-path` | `Sources/PuaKit/Dialer.swift` |
| Diagnostics: `doctor`, `selftest`, `devices`, `processes`, `ui-dump` | `Doctor.swift`, `SelfTest.swift`, `main.swift` |

## Decisions

| Decision | Why | Evidence |
| --- | --- | --- |
| Use Continuity and the Phone app instead of a custom tunnel | There is no public iOS API for cellular call audio. The Mac is the only place where the media is reachable. | external M14 |
| Use a real HAL driver instead of a driverless tap aggregate | The tap aggregate works system-wide, but the Phone app hides aggregate devices from its Microphone menu. | local-probes P2 and P3 |
| No virtual output sink | Muting the `avconferenced` tap keeps caller audio off the speakers, so the Phone app's output needs no virtual sink. `--monitor` keeps it audible. | Apple `CATapMuteBehavior`; `pua selftest` (muted tap, inaudible) |
| Split the loopback into an input-only mic and an output-only feed | During a call avconferenced opens the mic through Voice Processing, which enables a software reference stream of the same device's output and cancels it as echo. On a single in/out loopback the injected voice died within ~1 s (live call: avconferenced `averageInputPower` −88 → −120 dB). The two devices share a clock domain but are not related devices. | coreaudiod `softwareReferenceStreamEnabled=1` on `dev.pua.callmic.device`; VPIO probe below |
| Detect "answered" from callservicesd's `CallConnected` log line | The relay call banner (`<contact>, Using Your iPhone - 0:02`) embeds the timer in a longer AX label, so the anchored timer match never fired and no audio was sent. | Live call 2026-11-16 12:00:38 |
| On-device STT and LLM, cloud TTS | Measured on this Mac: Foundation Models first token 0.33 s, short reply 0.6–0.9 s; `SpeechTranscriber` final 0.12 s after the audio. ElevenLabs Flash streams 48 kHz PCM for a natural voice; the macOS voice is the offline fallback. Only reply text leaves the Mac. | `scratchpad` probe; live call below |
| Half duplex, no echo margin | The iPhone cancels the agent's voice: the caller track stayed silent while the agent spoke. A 0.4 s post-turn margin dropped the caller's instant reply to the greeting, so recognizer results are kept when they end after the turn boundary. | Live call 2026-11-16 (0:10 reply missed) |
| Ring of 16384 frames, cleared on read | Plenty of headroom for any IO buffer size. A stalled writer produces silence, not a loop. | Driver comments |
| Activate Phone before pressing its menu items | AXPress on a background app's menu item returns success but does nothing. | Local test: the route only applied after activation |
| Dial through a Shortcut, with `tel:` as a fallback | `tel:` needs a confirmation click. The Shortcut Call action does not, after the first approval. | external M4; live dial 2026-11-16 |
| Plain PCM16 on stdin and stdout, JSONL on stderr | Existing STT/TTS pipes (whisper.cpp, `say`, cloud TTS) plug in unchanged. | README examples |
| Engines behind protocols with a name registry | STT, model and voice change faster than the call path. A new engine is one file and one table entry; the config selects it. Turn-taking stays in one place, so every engine gets the same timing behaviour. | `swift test`; offline conversation with the refactored engines |
| Route the mic per incoming call, while it rings | Leaving the Phone mic on PUA Call Mic between calls would silence the owner on calls they answer themselves. Ring time covers the route switch and engine setup, so the greeting starts right after Accept. | Design; not yet observed live |
| pua's call rules appended to every system prompt | Custom prompts keep working without knowing the `[hangup]` marker or the spoken style. The rule was tightened after the on-device model appended `[hangup]` to an ordinary reply in an offline run. | Offline conversation, 2026-11-16 |
| CLI-only, with TCC on the host terminal | Smallest build. Accessibility, System Audio Recording and Microphone permissions attach to the terminal or agent app that runs `pua`. | A separate signed .app would keep the grants stable across terminals; possible follow-up. |

## Verified on this Mac (macOS 27.0.1, arm64)

| Check | Result |
| --- | --- |
| `swift build -c release`, `make driver` (`-Werror`, arm64 and x86_64) | build clean, no warnings |
| `pua selftest` downlink: muted tap on a helper process playing 440 Hz | peak 0.25 (equal to the source), 441 Hz, inaudible |
| `pua audio-stream --pid <afplay> --capture-only --max-seconds 3` | 146,400 frames (3.05 s) of PCM16, peak 7999 out of 8000, 443 Hz |
| `pua route setup --mic "EMEET SmartCam C60E 4K"`, then `pua route restore` | Selection applied and journaled, then restored to *Use System Setting* |
| `pua shortcut install --no-open` | Signed `AEA1` file decodes to `gettext` plus `com.apple.mobilephone.call`, Apple System Integration CA 4 chain |
| `pua doctor` | Each prerequisite reported separately, with its next action |
| Driver install (`scripts/install-driver.sh`, via the macOS admin prompt) | `PUA Call Mic` loaded: virtual, 1 in / 1 out |
| `pua selftest` uplink: 880 Hz rendered into `PUA Call Mic`, read back from its input | peak 0.30 (equal to the written level), 882 Hz |
| Phone app Audio menu | `PUA Call Mic` listed under Microphone (not Output). `pua route setup` selected it, `restore` reverted it. |
| `ffmpeg` (AVFoundation mic client) recording `PUA Call Mic` while `pua audio-stream --playback-only` plays a 660 Hz tone from stdin | peak 1638 = 32767 × 0.4 × ⅛ (lavfi sine amplitude), 660 Hz |
| `pua shortcut install` | Signed, imported through AX ("Add Shortcut"), listed by `shortcuts list` |
| Live relay call to the owner's second line (2026-11-16) | Dial via Shortcut (one-time permission auto-approved), `CallConnected` detected, `avconferenced` confirmed as the call media process (`running_output` and `VCAudioIO`). Driver 0.1 uplink was cancelled by Voice Processing after ~1 s (see Decisions). |
| Live relay call with driver 0.2 (2026-11-16 12:13) | Full 59.4 s demo delivered: avconferenced mic `averageInputPower` −12 to −41 dB with rising `voiceActivityCount`, −120 dB during the scripted listening gap. Downlink tap captured the far end (rms 331 in the gap vs 1 while the demo spoke). Hang-up via AX `End` in the Notification Center banner; route restored. |
| `pua converse` offline (afplay plays a scripted caller, `--pid`) | 3 exchanges, the model said goodbye and requested hang-up; stereo WAV with caller left, agent right |
| Live AI conversation with `pua converse --dial … --record` (2026-11-16, 0.3.0) | 87 s, 6 agent turns, 5 caller turns answered; caller hung up. Reply gap in the recording 2.1–3.1 s (median 2.8 s). One immediate reply missed (fixed in 0.3.1, verified offline with an overlapping caller). Recording in `docs/demo/`. |
| 0.4.0 offline: `swift test` (7 tests); `pua converse` against a scripted caller with the engine registry | All pass. Two runs: the caller's question answered (reply gap 3.0 s), hang-up only after "Goodbye." |
| 0.4.0 `pua listen --once`, then Ctrl-C | Engines prepared, `listening` emitted, clean exit with 0 calls |
| VoiceProcessingIO on `PUA Call Mic` while `audio-stream` plays the demo (no call) | Driver 0.1: −61 then −86 to −138 dBFS (cancelled). Driver 0.2: −13 to −34 dBFS for the whole clip. |

## Known gaps

* **Call UI:** observed live for outgoing relay calls: the call lives in a Notification Center
  banner (`FACETIME_NOTIFICATION`) with `Mute`, `Keypad`, `More` and `End`, and the label
  `<contact>, Using Your iPhone - 0:02`. Incoming-call labels (`Accept`, `Answer`, `Decline`) have not been observed live yet.
* **Answering:** `pua listen` has not answered a live call yet. Open questions: the incoming
  banner's button labels, whether switching the Phone mic while the call rings keeps the banner,
  and whether answering works while the Mac is locked (probably not: Accessibility needs an
  unlocked session).
* **Media process:** `avconferenced` confirmed live (`running_output`, `VCAudioIO`, VPIO aggregate).
* **Per-call isolation:** the tap covers the whole `avconferenced` process (FaceTime audio would
  be included too).
* **Turn-taking:** `converse` is half duplex. The caller cannot interrupt the agent (no
  barge-in), and end of turn is a fixed silence window. `audio-stream` still leaves STT/TTS to
  the agent.
* **Model depth:** the on-device model is fast but small. It misread "what is my name?" in the
  live demo.
