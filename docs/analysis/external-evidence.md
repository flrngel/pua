# External evidence (official, scholarly, community)

Method: web search and fetch only. Some pages were read through a summarizer, so quotes here are
paraphrases. Confidence ratings: **high** means an official source or two or more independent
sources; **medium** means one solid source; **low** means a single informal report. The
"Checked here" column refers to [local-probes.md](local-probes.md) (P numbers) and to the live
calls recorded in [pua-design.md](pua-design.md).

## Mac and iPhone

| # | Claim | Conf. | Sources | Checked here |
| --- | --- | --- | --- | --- |
| M1 | Continuity calls need Wi-Fi on both devices, the same Apple Account, FaceTime with the phone number enabled, and the iPhone allowing calls on the Mac. | high | [Apple Phone guide (macOS 26)](https://support.apple.com/en-ca/guide/phoneapp/phn4828a6/1.0/mac/26), [iGeeksBlog](https://www.igeeksblog.com/how-to-use-phone-app-on-macos-tahoe/) | Confirmed live: relay calls failed ("iPhone Calls Not Available", callservicesd `DeviceUnavailable`) until the iPhone allowed calls on this Mac. |
| M2 | macOS 26 Tahoe brought the Phone app to the Mac (Call Screening, Hold Assist, recording, Live Translation) over Continuity. | high | [Apple Newsroom](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/), [MacRumors](https://www.macrumors.com/2025/06/09/phone-app-macos-tahoe/) | Phone.app present as `com.apple.mobilephone` (P1) |
| M3 | Phone.app has no AppleScript dictionary or automation hook. | medium | Not found in any source; checked locally with `sdef` (error -192) | Confirmed (P1). `pua` uses Accessibility and Shortcuts instead. |
| M4 | `open tel://…` on macOS shows a "Click to Call" confirmation. | medium | [desty.github.io phone agent](https://desty.github.io/en/blog/23-phone-ai-agent/) | `pua` dials through a Shortcut instead; after a one-time "Allow" it needs no click (live). |
| M5 | Core Audio process taps (macOS 14.2 or later): `CATapDescription`, then `AudioHardwareCreateProcessTap`, then an aggregate device with `kAudioAggregateDeviceTapListKey`, read through an IOProc. Targeted by PID translated to an AudioObjectID. | high | [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps), [AudioCap](https://github.com/insidegui/AudioCap), [recall.ai](https://www.recall.ai/blog/core-audio-taps) | `pua selftest`: a muted tap captured a 440 Hz helper at source amplitude. |
| M6 | Taps need `NSAudioCaptureUsageDescription` ("System Audio Recording", `kTCCServiceAudioCapture`). There is no public request API. A denied tap returns `noErr` with zero-filled buffers. | high / medium | AudioCap; [dev.to "2000 buffers of nothing"](https://dev.to/nickdelv/2000-buffers-of-nothing-3i8) | `pua selftest` checks for non-zero RMS for this reason. |
| M7 | Taps work at the HAL level, so daemon output (no window) can be captured. ScreenCaptureKit cannot do this. | medium | dev.to (above) | Confirmed live: `pua` taps the daemon `avconferenced` and captures the far end. |
| M8 | Which daemon renders Continuity call audio: one write-up says `callservicesd` for cellular and `avconferenced` for FaceTime. | low | dev.to (above) | Contradicted live: during a cellular relay call `avconferenced` was the process with `running_output` and `VCAudioIO`, and tapping it captured the caller. |
| M9 | AudioServerPlugIn: a `.driver` bundle in `/Library/Audio/Plug-Ins/HAL`. coreaudiod does not hot-load plug-ins, so restart coreaudiod or reboot. | high | [Apple: Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in), [coreaudio-api list](https://lists.apple.com/archives/coreaudio-api/2008/Mar/msg00244.html), [BlackHole](https://github.com/ExistentialAudio/BlackHole) | `scripts/install-driver.sh` restarts coreaudiod; `PUA Call Mic` appeared afterwards. |
| M10 | Signing: one project says macOS 26 or later needs a Developer Program signature for HAL drivers. | low | Search result only | Not tested with an ad-hoc signature; the Developer ID signed driver loads on macOS 27.0.1. |
| M11 | Pattern "loopback driver as the call microphone, real speakers as output" (OpenClaw FaceTime plugin; FaceTime only, cellular rejected). | high (for that project) | [OpenClaw FaceTime plugin](https://docs.openclaw.ai/plugins/facetime.md) | `pua` uses the same pattern, and it also works for cellular relay calls (live). |
| M12 | Using BlackHole as the call *output* caused call-volume ducking and silence, so that author used a tap instead. | low | desty.github.io | `pua` captures with a muted tap and needs no output sink. |
| M13 | AX against call UI did not work for one author (no window for the call panel), so they clicked screen coordinates. | medium | desty.github.io | AX works on the Notification Center call banner (`Mute`, `Keypad`, `More`, `End`), live. |
| M14 | No public iOS API gives access to remote caller audio. Phone.app is a CallKit client. | high | [Apple DTS forum 848873](https://developer.apple.com/forums/thread/848873) | Explains why every solution runs on the Mac and none on the iPhone |
| M15 | `CXCallObserver` on macOS: documentation is ambiguous, and whether it sees Continuity calls was not found. | low | [CXCallObserver](https://developer.apple.com/documentation/callkit/cxcallobserver), [forum 852785](https://developer.apple.com/forums/thread/852785) | `pua` does not use CallKit; it detects the answer from callservicesd's `CallConnected` log line. |
| M16 | Alternative transport: Bluetooth HFP (the Mac acts as a hands-free unit through `IOBluetoothHandsFreeDevice`) with SCO audio. | medium | [phonebt](https://github.com/icoainc/phonebt) | Not used |
| M17 | `TUCall` / TelephonyUtilities is private SPI, and `callservicesd` enforces entitlements (`access-calls`, `modify-calls`). | low | [WebKit TUCallSPI.h](https://opensource.apple.com/source/WebCore/WebCore-7605.3.8/PAL/pal/spi/mac/TUCallSPI.h.auto.html) | Not used |

## Scholarly

| Paper | Relevance |
| --- | --- |
| Stute et al., *Disrupting Continuity of Apple's Wireless Ecosystem Security*, USENIX Security 2021 ([link](https://www.usenix.org/conference/usenixsecurity21/presentation/stute); thesis [tuprints 20603](https://tuprints.ulb.tu-darmstadt.de/20603)) | Reverse-engineers Continuity discovery and authentication (BLE, mDNS, AWDL) for Handoff, Universal Clipboard and Wi-Fi Password Sharing. Does **not** cover the cellular call relay media path. |
| Martin et al., *Handoff All Your Privacy*, PETS 2019 ([link](https://crysp.petsymposium.org/popets/2019/popets-2019-0057.php), [arXiv 1904.10600](https://arxiv.org/abs/1904.10600)) | BLE Continuity advertisement format and privacy leaks. Discovery layer only. |
| Celosia and Cunche, *Discontinued Privacy*, PETS 2020 ([link](https://crysp.petsymposium.org/popets/2020/popets-2020-0003.php)) | Continuity BLE identifiers enable tracking. Discovery layer only. |

Takeaway: the literature covers Continuity **discovery and authentication**, not call media.
No paper documents a third-party hook into the relayed call. Working one layer higher, on the
Mac's audio graph, needs no protocol reverse engineering.

## Android

| # | Claim | Conf. | Sources |
| --- | --- | --- | --- |
| A1 | `am start -a android.intent.action.CALL -d tel:N`; `input keyevent KEYCODE_ENDCALL`; `dumpsys telephony.registry` `mCallState` (0, 1, 2); `dumpsys telecom` | medium | [SO 25897758](https://stackoverflow.com/questions/25897758), [stackpointer](https://stackpointer.io/?p=382), [AOSP dialer testing](https://source.android.com/docs/devices/automotive/hmi/dialer/testing) |
| A2 | scrcpy 3.2 added the audio sources `voice-call`, `voice-call-uplink` and `voice-call-downlink`. Audio needs Android 11 or later (12 or later works out of the box). | high | [scrcpy v3.2](https://github.com/Genymobile/scrcpy/releases/tag/v3.2), [doc/audio.md](https://github.com/Genymobile/scrcpy/blob/master/doc/audio.md) |
| A3 | Limits: one source at a time; the directions can come back mixed (Pixel 8 Pro, Android 15); no packets during silence; some Samsung devices return no audio. | medium–high | [scrcpy PR 5870](https://github.com/Genymobile/scrcpy/pull/5870) |
| A4 | Injecting into a call is not in mainline scrcpy. PR 6439 (`--client-audio-source`, through AudioPolicy reflection) gives mixed results. | medium | [scrcpy PR 6439](https://github.com/Genymobile/scrcpy/pull/6439) |
| A5 | Stock Android has no app-level uplink injection for normal cellular calls. | medium | [SO 5268964 (mirror)](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/5268964/stream-audio-to-a-phone-call-android) |
