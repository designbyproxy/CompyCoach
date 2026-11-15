import AppKit
import CoreGraphics

// MARK: - Exercise model

enum Exercise {
    case squats, pushups, situps, standStretch, eyeRelax, walk

    var displayName: String {
        switch self {
        case .squats:       return "SQUATS"
        case .pushups:      return "PUSH-UPS"
        case .situps:       return "SIT-UPS"
        case .standStretch: return "STAND & STRETCH"
        case .eyeRelax:     return "20–20–20"
        case .walk:         return "WALK"
        }
    }

    // Large number shown in the panel; empty means no quantity shown.
    var quantityText: String {
        switch self {
        case .squats:       return "10"
        case .pushups:      return "8"
        case .situps:       return "12"
        case .standStretch: return "45"
        case .eyeRelax:     return "20"
        case .walk:         return ""
        }
    }

    var unitText: String {
        switch self {
        case .squats:       return "REPS"
        case .pushups:      return "REPS"
        case .situps:       return "REPS"
        case .standStretch: return "SECONDS"
        case .eyeRelax:     return "SECONDS"
        case .walk:         return ""
        }
    }

    var logKey: String {
        switch self {
        case .squats:       return "squats"
        case .pushups:      return "pushups"
        case .situps:       return "situps"
        case .standStretch: return "standStretch"
        case .eyeRelax:     return "eyeRelax"
        case .walk:         return "walk"
        }
    }

    // If true, the panel asks "how many did you do?" with a text field.
    var requiresRepInput: Bool {
        switch self {
        case .squats, .pushups, .situps: return true
        default:                return false
        }
    }

    // If true, the panel counts the target down second-by-second (held timer).
    var isTimed: Bool {
        switch self {
        case .standStretch, .eyeRelax: return true
        default:                       return false
        }
    }

    // Button label shown while a timed exercise is still counting down.
    var inProgressLabel: String {
        switch self {
        case .standStretch: return "STRETCHING..."
        case .eyeRelax:     return "LOOKING AWAY..."
        default:            return ""
        }
    }
}

// MARK: - Trigger engine

@MainActor
final class TriggerEngine: ObservableObject {
    static let shared = TriggerEngine()

    @Published private(set) var nextFireDate = Date.distantFuture

    private var timer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    private var rotationIndex = 0

    // Set when the user taps "Skip for now" on a walk — forces the walk to
    // resurface on the next interruption instead of waiting a full rotation.
    private var walkDeferred = false

    // Call-guard state: when a timer fires while the camera or screen sharing
    // is active, we hold off without advancing the rotation.  A poll timer
    // checks every 30 s; once the session clears we wait another 30 s and fire.
    private var callWatchPending = false
    private var callWatchTimer: DispatchSourceTimer?
    private var callWatchStarted: Date?

    // Upper bound on how long a single deferral may hold. Past this, a "still in a
    // call" reading is far more likely a stuck detector (e.g. a device that reports
    // itself permanently in use) than a real session, so the watcher gives up and
    // returns to the normal schedule. It never escalates to showing the panel —
    // a missed nudge is cheap, a takeover mid-meeting is not.
    private let maxCallHold: TimeInterval = 3 * 60 * 60

    // Walk sits at the end so it fires roughly every 6 cycles.
    private let rotation: [Exercise] = [.squats, .pushups, .standStretch, .situps, .eyeRelax, .walk]

    private init() {}

    func start() {
        scheduleNext()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.nextFireDate <= Date() {
                    // Interrupt was due while asleep — give a fresh interval.
                    self.scheduleNext()
                } else {
                    // Time still remaining — re-arm the timer to the original fire date.
                    self.rescheduleToFireDate()
                }
            }
        }
    }

    func skipNext() {
        scheduleNext()
    }

    /// Called when the user taps "Skip for now" on a walk. Logs a skip and
    /// arranges for the walk to come back on the next interruption.
    func deferWalk() {
        walkDeferred = true
        DataStore.shared.logSkip()
    }

    private func scheduleNext() {
        timer?.cancel()
        timer = nil
        let interval = TimeInterval.random(in: 45 * 60 ... 75 * 60)
        nextFireDate = Date().addingTimeInterval(interval)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval)
        t.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.timerFired() }
        }
        t.resume()
        timer = t
    }

    private func rescheduleToFireDate() {
        timer?.cancel()
        timer = nil
        let remaining = nextFireDate.timeIntervalSinceNow
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + remaining)
        t.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.timerFired() }
        }
        t.resume()
        timer = t
    }

    private func timerFired() {
        let idleSeconds = [CGEventType.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
        guard idleSeconds < 5 * 60 else {
            scheduleNext()
            return
        }

        // If we're already waiting for a call to end, let the existing watcher
        // handle firing — don't double-queue an exercise or restart the watcher.
        guard !callWatchPending else {
            scheduleNext()
            return
        }

        Task { @MainActor in
            let blocking = await CallDetector.isBlocking()
            if blocking {
                // Hold the pending fire without advancing the rotation.
                // The call watcher will pick the exercise once the call clears.
                callWatchPending = true
                startCallWatcher()
            } else {
                InterruptionPanelManager.shared.show(exercise: nextExercise())
            }
        }
        scheduleNext()
    }

    // Polls every 30 s; once the camera/screen-share clears, waits 30 more seconds
    // then fires the deferred exercise.
    private func startCallWatcher() {
        callWatchStarted = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.checkCallCleared() }
        }
        t.resume()
        callWatchTimer = t
    }

    private func checkCallCleared() {
        Task { @MainActor in
            if let started = callWatchStarted, Date().timeIntervalSince(started) > maxCallHold {
                endCallWatch()
                return
            }

            guard !(await CallDetector.isBlocking()) else { return }

            // Looks clear — wait out a 30 s buffer, then re-check before firing.
            // The watcher and the pending flag stay in place across the buffer so a
            // call rejoined during it keeps the panel suppressed, and so the regular
            // timer can't slip a second panel through in the meantime.
            try? await Task.sleep(nanoseconds: 30_000_000_000)

            guard !(await CallDetector.isBlocking()) else { return }

            endCallWatch()
            InterruptionPanelManager.shared.show(exercise: nextExercise())
        }
    }

    private func endCallWatch() {
        callWatchTimer?.cancel()
        callWatchTimer = nil
        callWatchPending = false
        callWatchStarted = nil
    }

    private func nextExercise() -> Exercise {
        // A walk that was skipped-for-now resurfaces here, ahead of the rotation.
        if walkDeferred && !isWalkDoneToday() {
            walkDeferred = false
            return .walk
        }

        var exercise = rotation[rotationIndex % rotation.count]
        rotationIndex += 1

        // Don't repeat the walk once it's actually been completed today.
        if case .walk = exercise, isWalkDoneToday() {
            exercise = rotation[rotationIndex % rotation.count]
            rotationIndex += 1
        }

        return exercise
    }

    // The walk is "done" only once a walk has been confirmed (logged) today —
    // skipping or dismissing the panel does not count.
    private func isWalkDoneToday() -> Bool {
        DataStore.shared.entries.contains {
            $0.exercise == "walk" && Calendar.current.isDateInToday($0.timestamp)
        }
    }
}
