# Android: call audio over adb (feasibility)

Scope: analysis only. `pua` implements Mac and iPhone. Sources are in
[external-evidence.md](external-evidence.md) (A rows).

## Transport and control

There is no relay to a computer on Android, so the computer has to reach into the phone. The
usual route is adb with USB debugging and an authorized computer. Code runs as the **shell
UID** either through `adb shell` commands or by pushing a dex-in-JAR and starting it with
`app_process`. That is how scrcpy works, and nothing is installed as an app.

Call control as the shell UID (A1):

* Dial: `am start -a android.intent.action.CALL -d tel:NUMBER` (the shell has `CALL_PHONE`).
* Answer and hang up: `input keyevent KEYCODE_CALL` / `KEYCODE_ENDCALL`, or taps found through
  the UI tree (`uiautomator dump`, or `UiAutomation` from an `app_process` helper).
* State: `dumpsys telephony.registry` (`mCallState` 0 idle, 1 ringing, 2 offhook) and
  `dumpsys telecom`.

## Call audio

* **Capture:** `MediaRecorder.AudioSource.VOICE_CALL`, `VOICE_UPLINK` and `VOICE_DOWNLINK` are
  reachable from the shell UID on Android 11 and later. scrcpy 3.2 ships them as
  `--audio-source=voice-call*` (A2). Uplink and downlink can come back mixed, there are no
  packets during silence, and some devices return nothing (A3).
* **Playback into the call:** stock Android has no public path (A5). The candidates all depend
  on the firmware:
  * Routing an `AudioTrack` to `TYPE_TELEPHONY` or an in-call output.
  * Reflection into `AudioPolicy`, as scrcpy PR 6439 does for microphone injection (A4).
  * The system API `AudioManager.getCallUplinkInjectionAudioTrack`, which requires
    `CALL_AUDIO_INTERCEPTION` and is not granted to the shell.
* Moving PCM between the phone and the computer: a TCP socket in the helper, reached through
  `adb forward`.

## Why Android differs from iPhone

| | iPhone via Mac | Android via adb |
| --- | --- | --- |
| Where the call media lives | On the Mac (Continuity relay into `avconferenced`) | On the phone's modem and audio DSP |
| Capture | Process tap on the Mac (public API, macOS 14.2 or later) | `AudioRecord` voice-call sources as the shell UID (Android 11 or later; varies by device) |
| Injection | Virtual microphone selected in Phone.app (public HAL plug-in API) | No public path. Depends on the firmware and vendor. |
| Control | Shortcuts plus Accessibility on the Mac | Intents, keyevents and the UI tree as the shell UID |
| Requires | Same Apple Account, Wi-Fi, "Calls on Other Devices", macOS 26 Phone app | USB debugging and an authorized computer |
