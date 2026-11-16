import AppKit
import CoreAudio
import Foundation

/// Reports each prerequisite separately, with the next action for anything missing.
public enum Doctor {
    public struct Check {
        public let name: String
        public let ok: Bool
        public let detail: String
        public let action: String?
        public var json: [String: Any] {
            var o: [String: Any] = ["name": name, "ok": ok, "detail": detail]
            if let action { o["action"] = action }
            return o
        }
    }

    public static func run() -> [Check] {
        var checks: [Check] = []
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let tapsOK = v.majorVersion > 14 || (v.majorVersion == 14 && v.minorVersion >= 2)
        checks.append(Check(name: "macos", ok: tapsOK, detail: version,
                            action: tapsOK ? nil : "macOS 14.2 or later is required for process taps"))

        let phoneInstalled = FileManager.default.fileExists(atPath: "/System/Applications/Phone.app")
        checks.append(Check(name: "phone_app", ok: phoneInstalled,
                            detail: phoneInstalled ? "installed" : "missing",
                            action: phoneInstalled ? nil : "macOS 26 or later provides the Phone app for iPhone calls"))
        let phoneRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: CallControl.phoneBundleID).isEmpty
        checks.append(Check(name: "phone_app_running", ok: phoneRunning, detail: phoneRunning ? "running" : "not running",
                            action: phoneRunning ? nil : "open -a Phone"))

        let trusted = AX.isTrusted
        checks.append(Check(name: "accessibility", ok: trusted, detail: trusted ? "trusted" : "not trusted",
                            action: trusted ? nil : "pua permissions (then enable this terminal in Privacy & Security > Accessibility)"))

        let mic = AudioDevice.find(uid: callMicUID)
        checks.append(Check(name: "call_mic_driver", ok: mic != nil, detail: mic.map { "\($0.name) id=\($0.id)" } ?? "not loaded",
                            action: mic == nil ? "sudo scripts/install-driver.sh" : nil))

        let audioPIDs = callAudioPIDs(bundleID: "com.apple.avconferenced")
        checks.append(Check(name: "call_audio_process", ok: !audioPIDs.isEmpty,
                            detail: audioPIDs.isEmpty ? "avconferenced not found" : "avconferenced pid \(audioPIDs.map(String.init).joined(separator: ","))",
                            action: nil))

        let shortcut = Dialer.shortcutInstalled()
        checks.append(Check(name: "dial_shortcut", ok: shortcut, detail: shortcut ? Dialer.defaultShortcutName : "not installed",
                            action: shortcut ? nil : "pua shortcut install"))

        if trusted, phoneRunning, let status = try? PhoneRoute.status() {
            let current = status["microphone"] as? String ?? "?"
            let routed = mic != nil && current == mic!.name
            checks.append(Check(name: "phone_mic_route", ok: routed, detail: "Phone microphone: \(current)",
                                action: routed ? nil : "pua route setup (or pass --route to audio-stream)"))
        }

        let call = CallControl.snapshot()
        checks.append(Check(name: "call_state", ok: true, detail: call.state.rawValue, action: nil))
        return checks
    }
}
