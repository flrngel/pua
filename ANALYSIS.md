# ANALYSIS: How iPhone calls can be tunneled through a Mac

Analysis date: 2026-11-16. Analysis host: macOS 27.0.1 (arm64), Xcode 27.2.

Evidence comes from Apple documentation, public community and scholarly sources, experiments on
this Mac, and live calls placed with `pua`. The details are split into:

| File | Contents |
| --- | --- |
| [docs/analysis/external-evidence.md](docs/analysis/external-evidence.md) | Official docs, scholarly papers and community reports, with a confidence rating per claim and what was checked here. |
| [docs/analysis/local-probes.md](docs/analysis/local-probes.md) | Experiments on this Mac: a cross-process tap-device probe and the Phone app's device filtering. |
| [docs/analysis/pua-design.md](docs/analysis/pua-design.md) | How `pua` implements it, the decisions with evidence, and what was verified on live calls. |
| [docs/analysis/android.md](docs/analysis/android.md) | Android over adb: control, call-audio capture and why injection is device dependent. |

## TL;DR

Nothing is tunneled over the network by a third party. **Apple Continuity** already relays the
iPhone's cellular call to the Mac (Phone app, macOS 26 or later), so the Mac end of the call is
a normal macOS audio client. A program attaches to it with public APIs:

| Concern | Mechanism | Evidence |
| --- | --- | --- |
| Call transport, iPhone to Mac | Continuity "Calls on Other Devices". The Mac **Phone app** (`com.apple.mobilephone`) shows the call, `callservicesd` manages it, `avconferenced` carries the media. | External M1, M2. Live: calls were rejected (`DeviceUnavailable`) until the iPhone allowed this Mac; during calls `avconferenced` rendered the audio (`VCAudioIO`). |
| Dial out | A Shortcut: *Get Text (Shortcut Input)* then the Phone **Call** action (`com.apple.mobilephone.call`), run with `/usr/bin/shortcuts run … --input-path`. `tel:` URLs need a confirmation click. | External M4. Live: dialed after a one-time "Allow". |
| Answer detection | `callservicesd` logs `Handle incoming CallConnected message` when the far end answers. | Live call; the banner timer alone was not a reliable signal. |
| Call control | **Accessibility** on the Notification Center call banner (`FACETIME_NOTIFICATION`: `Mute`, `Keypad`, `More`, `End`; label `<contact>, Using Your iPhone - 0:02`) and the Phone app. Phone.app has no AppleScript dictionary. | Live call; P1 (`sdef` error -192); external M3, M13. |
| Hear the caller (downlink) | **Core Audio process tap** (macOS 14.2 or later) on `avconferenced`, muted so the caller does not play on the speakers, read as 48 kHz mono Float32. | Apple tap docs (M5–M7). Live: far end captured. |
| Speak to the caller (uplink) | A **HAL AudioServerPlugIn** virtual microphone, selected as the Phone app's microphone through its *Audio* menu (AX). It has to be a real driver: the Phone app hides aggregate devices. The microphone must be **input-only**: Voice Processing in `avconferenced` cancels a device's own output as echo. | P2, P3; live calls with driver 0.1 (voice cancelled after ~1 s) and 0.2 (full 59 s delivered). |

## Architecture (as built in `pua`)

```
 iPhone (cellular call)                    Mac
 ─────────────────────                    ──────────────────────────────────────────────────────────
  Phone ──Continuity relay (Wi-Fi/iCloud)──▶ callservicesd / avconferenced ◀──── Phone.app (UI)
                                                │ downlink                        ▲   ▲ AX: Audio menu
                                                │ (process tap, muted)            │   │ Mic = PUA Call Mic
                                                ▼                                 │
                                              pua ──AX press──▶ notificationcenterui (End, …)
                                                │  ▲  uplink via AUHAL into PUA Call Feed ─▶ PUA Call Mic
                                                ▼  │
                                  stdout PCM16 ◀┘  └▶ stdin PCM16  + stderr JSONL
                                                ▼
                       agent (STT/TTS), or the built-in `pua converse`
  Dial:  pua → /usr/bin/shortcuts run "PUA Dial" --input-path <file> → com.apple.mobilephone.call
```

## Why there is no simpler path

* No public iOS API exposes remote caller audio, so nothing can run on the iPhone (M14).
* The research literature covers Continuity discovery and authentication, not the call media
  (external-evidence.md, Scholarly).
* Bluetooth HFP (the Mac acting as a hands-free unit) is an alternative transport, with
  narrowband SCO audio (M16).
* A driverless virtual microphone works system-wide but cannot be picked in the Phone app (P3).

## Android

The call media stays on the phone, so a computer reaches it over adb as the shell UID.
Capture is possible on Android 11 and later through the voice-call `AudioRecord` sources (as in
scrcpy 3.2). Injecting audio into a cellular call has no stock public path and depends on the
device. See [android.md](docs/analysis/android.md).

## What `pua` builds

See [pua-design.md](docs/analysis/pua-design.md): the `pua` CLI (Swift, macOS 26), the
two-device `PUA Call Mic` driver (C), the PCM16 `audio-stream` contract for agents, and
`converse` for AI conversations with on-device speech recognition and language model.
