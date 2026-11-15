import Foundation
import AppKit
import CoreMediaIO
import CoreAudio

// MARK: - CallDetector

// Detects whether the user is in a meeting — on camera, on mic, or screen sharing —
// so the TriggerEngine can hold off until the session ends.
//
// There is no public API that reports "some app is sharing its screen", so detection is
// a union of signals, each covering a case the others miss:
//
//   1. Camera in use (CoreMediaIO) — any app holding the camera open.
//   2. Microphone in use, PER PROCESS (CoreAudio, macOS 14.4+) — catches camera-off
//      meetings, which is the case that matters most for screen sharing: you can
//      present with video off, but essentially never with the mic closed.
//   3. macOS's own screensharingd — Remote Screen Sharing / remote control.
//   4. A dedicated meeting app being frontmost — fallback only, used when the
//      per-process mic API is unavailable (pre-14.4).
//
// Why per-process and not per-device for the mic:
// kAudioDevicePropertyDeviceIsRunningSomewhere on the *device* reads as running
// continuously for always-clocked external interfaces (e.g. a USB audio interface),
// with no app capturing at all. Gating on that would suppress every nudge forever.
// kAudioProcessPropertyIsRunningInput asks "is this process capturing input", which is
// the question we actually mean.

struct CallDetector {

    // Frontmost-app fallback list — deliberately only dedicated meeting apps.
    // Browsers and chat apps are excluded: they are frontmost most of the day, so
    // gating on them would suppress nudges indefinitely.
    private static let meetingApps: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "com.gotomeeting.GoToMeeting",
        "com.apple.FaceTime",
    ]

    // Processes that may hold the mic open without a call in progress (wake-word
    // listening, accessibility). Ignored so they can't block nudges permanently.
    private static let ignoredInputProcesses: Set<String> = [
        "com.apple.SiriNCService",
        "com.apple.siri",
        "corespeechd",
        "universalaccessd",
    ]

    // MARK: Camera

    // Returns true while the camera is running in any process.
    // CompyCoach never opens the camera, so a running device means someone else has it.
    static func isCameraInUse() -> Bool {
        var listAddr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement:  0
        )

        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &listAddr, 0, nil, &dataSize
        ) == kCMIOHardwareNoError, dataSize > 0 else { return false }

        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var deviceIDs = [CMIODeviceID](repeating: 0, count: count)
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &listAddr, 0, nil, dataSize, &dataSize, &deviceIDs
        ) == kCMIOHardwareNoError else { return false }

        for deviceID in deviceIDs {
            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement:  0
            )
            if CMIOObjectGetPropertyData(
                deviceID, &runningAddr, 0, nil,
                runningSize, &runningSize, &isRunning
            ) == kCMIOHardwareNoError, isRunning != 0 {
                return true
            }
        }
        return false
    }

    // MARK: Microphone (per process)

    // A mic poll distinguishes "no" from "couldn't tell": the latter falls through to
    // the frontmost-app fallback rather than being treated as an all-clear.
    enum MicState { case inUse, idle, unknown }

    static func microphoneState() -> MicState {
        guard #available(macOS 14.4, *) else { return .unknown }

        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return .unknown }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr, 0, nil, &dataSize, &processIDs
        ) == noErr else { return .unknown }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var polledAny = false

        for audioObject in processIDs {
            guard let pid = pid(of: audioObject) else { continue }

            var isRunningInput: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                audioObject, &runAddr, 0, nil, &size, &isRunningInput
            ) == noErr else { continue }

            polledAny = true
            guard isRunningInput != 0, pid != ownPID else { continue }
            guard !isIgnoredInputProcess(pid) else { continue }
            return .inUse
        }

        return polledAny ? .idle : .unknown
    }

    private static func pid(of audioObject: AudioObjectID) -> pid_t? {
        guard #available(macOS 14.4, *) else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(audioObject, &addr, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid
    }

    private static func isIgnoredInputProcess(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            // Not a bundled app (a daemon) — match on the executable name instead.
            return ignoredInputProcesses.contains(executableName(of: pid) ?? "")
        }
        if let bundleID = app.bundleIdentifier,
           ignoredInputProcesses.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return true
        }
        return ignoredInputProcesses.contains(executableName(of: pid) ?? "")
    }

    private static func executableName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard proc_pidpath(pid, &buffer, UInt32(PATH_MAX)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }

    // MARK: Screen sharing

    // macOS's built-in screen-sharing daemon (Remote Screen Sharing / remote control).
    // In-app sharing from Zoom/Meet/Teams has no public API, so that case is covered by
    // the camera and per-process mic signals instead.
    static func isSystemScreenSharing() -> Bool {
        isProcessRunning("screensharingd")
    }

    // MARK: Meeting app fallback

    static func isMeetingAppFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return meetingApps.contains(bundleID)
    }

    // MARK: Combined

    // Runs every check off the main thread and returns the combined result.
    static func isBlocking() async -> Bool {
        await Task.detached(priority: .utility) {
            if isCameraInUse() { return true }
            if isSystemScreenSharing() { return true }

            switch microphoneState() {
            case .inUse:   return true
            case .idle:    return false
            case .unknown: return frontmostIsMeetingApp()
            }
        }.value
    }

    // NSWorkspace is main-thread-affine; hop back for the frontmost-app read.
    private static func frontmostIsMeetingApp() -> Bool {
        if Thread.isMainThread { return isMeetingAppFrontmost() }
        return DispatchQueue.main.sync { isMeetingAppFrontmost() }
    }

    // MARK: Process check

    private static func isProcessRunning(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", name]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            // Couldn't launch pgrep — report "not running" rather than blocking forever.
            // (terminationStatus on a never-launched Process reads 0, which would
            //  otherwise be indistinguishable from a successful match.)
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
