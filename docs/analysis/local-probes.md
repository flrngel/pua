# Local probes on this Mac (2026-11-16, macOS 27.0.1 arm64)

These experiments informed `pua`'s design. None of them placed or answered a call.

## P1: Call components present

```
$ pgrep -lf 'avconferenced|callservicesd'
711 /System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd
873 /usr/libexec/avconferenced
$ plutil -extract CFBundleIdentifier raw /System/Applications/Phone.app/Contents/Info.plist
com.apple.mobilephone
$ sdef /System/Applications/Phone.app
sdef: couldn't get sdef for /System/Applications/Phone.app (error -192)
```

## P2: Driverless virtual microphone (tap-backed public aggregate)

Question: can we skip the HAL driver by exposing *our own process output* as a microphone?
The idea was a non-private `CATapDescription` with `muteBehavior = .muted` on a player process,
inside a **non-private** aggregate with `kAudioAggregateDeviceTapAutoStartKey`.

Steps:

* Process A (`mic`) taps `afplay -v 0.05 tone.wav`, a 440 Hz tone at amplitude 0.244.
* Process A then creates the aggregate `PUA Probe Mic` (`dev.pua.probe.mic`).
* A **separate** process B (`rec`) finds the device by UID and reads its input through an IOProc.

```
procobj 0 173 / tap 0 175 <uuid> / agg 0 176
found 132 / ioproc 0 start 0 / callbacks 281 peak 0.012206823
system_profiler: "PUA Probe Mic:  Input Channels: 1"
```

The measured peak, 0.0122, equals 0.244 × 0.05, so the real signal crossed the process
boundary. The aggregate is a working system-wide input device.

## P3: Phone app filters aggregate devices out of its Audio menu (decisive)

With the P2 aggregate alive, the Phone app (opened in the background, no call) was dumped through AX:

```
AXMenuBarItem t=Audio id=com.apple.facetime.menu.video
  AXMenuItem t=Microphone
  AXMenuItem t=Use System Setting        id=use_system_setting
  AXMenuItem t=EMEET SmartCam C60E 4K    id=emeet_smartcam_c60e_4k
  AXMenuItem t=MacBook Pro Microphone    id=macbook_pro_microphone
  AXMenuItem t=<user>'s iPhone … Microphone  (Continuity mics)
  AXMenuItem t=Output
  AXMenuItem t=Use System Setting        id=use_system_setting
  AXMenuItem t=VZ239 / LG HDR 4K / External Headphones / MacBook Pro Speakers
```

Neither `PUA Probe Mic` nor a pre-existing persistent aggregate device from another app is listed.
**The Phone app hides aggregate devices.** So a driverless microphone cannot be selected
in-app. It could only be reached by changing the *system default input* and relying on
`Use System Setting`, which is unverified for `avconferenced` and would affect every app.

Decision: `pua` ships a real AudioServerPlugIn (`PUA Call Mic`).

## P4: Accessibility reachability

Running `AXIsProcessTrusted()` from this terminal returned `true`. Phone.app menu items expose
stable identifiers (`use_system_setting`, a slugified device name) and the check state through
`AXMenuItemMarkChar`, which is enough to select and restore a route.

Probe sources (kept out of the repository): `mic.swift`, `rec.swift`, `ax.swift` in the session
scratchpad. `pua` reimplements them as `pua selftest`, `pua devices` and `pua ui-dump`.
