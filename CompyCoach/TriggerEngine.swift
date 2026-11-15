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

    // Sampling cadence. Each sample reads idle time and the call detector, then
    // advances the active-time countdown.
    private static let sampleInterval: TimeInterval = 15

    @Published private(set) var status: ActiveCountdown.Status = .running
    @Published private(set) var remaining: TimeInterval

    private var countdown: ActiveCountdown
    private var sampler: DispatchSourceTimer?
    private var sampleInFlight = false
    private var rotationIndex = 0

    // Set when the user taps "Skip for now" on a walk — forces the walk to
    // resurface on the next interruption instead of waiting a full rotation.
    private var walkDeferred = false

    // Set when the walk's turn came up but the weather was too cold or wet.
    // The walk is offered again on later nudges today once conditions improve.
    private var walkOwedDate: Date?

    // Walk sits at the end so it fires roughly every 6 cycles.
    private let rotation: [Exercise] = [.squats, .pushups, .standStretch, .situps, .eyeRelax, .walk]

    private init() {
        let first = Self.randomInterval()
        countdown = ActiveCountdown(remaining: first, now: Date(),
                                    maxSampleGap: Self.sampleInterval * 3)
        remaining = first
    }

    private static func randomInterval() -> TimeInterval {
        TimeInterval.random(in: 45 * 60 ... 75 * 60)
    }

    func start() {
        guard sampler == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.sampleInterval, repeating: Self.sampleInterval)
        t.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.sample() }
        }
        t.resume()
        sampler = t
    }

    func skipNext() {
        countdown.restart(remaining: Self.randomInterval())
        publish()
    }

    /// Called when the user taps "Skip for now" on a walk. Logs a skip and
    /// arranges for the walk to come back on the next interruption.
    func deferWalk() {
        walkDeferred = true
        DataStore.shared.logSkip()
    }

    // MARK: Sampling

    private func sample() {
        // The call probe and the weather check are async; never let samples overlap.
        guard !sampleInFlight else { return }
        sampleInFlight = true

        Task { @MainActor in
            defer { sampleInFlight = false }

            let panelShowing = InterruptionPanelManager.shared.isShowing
            // No need to probe for a call while a panel is already up.
            let inCall = panelShowing ? false : await CallDetector.isBlocking()

            let due = countdown.step(now: Date(),
                                     idleSeconds: Self.idleSeconds(),
                                     inCall: inCall,
                                     panelShowing: panelShowing)
            if due {
                countdown.restart(remaining: Self.randomInterval())
            }
            publish()

            if due {
                InterruptionPanelManager.shared.show(exercise: await nextExercise())
            }
        }
    }

    private func publish() {
        if status != countdown.status { status = countdown.status }
        remaining = countdown.remaining
    }

    private static func idleSeconds() -> TimeInterval {
        [CGEventType.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    // MARK: Exercise selection

    private func nextExercise() async -> Exercise {
        let walkPending = (walkDeferred || isWalkOwedToday()) && !isWalkDoneToday()

        // A walk that was skipped-for-now, or bumped by bad weather earlier today,
        // resurfaces ahead of the rotation as soon as the weather allows it.
        var walkBlockedByWeather = false
        if walkPending {
            if await WeatherService.shared.isWalkWeatherOK() {
                walkDeferred = false
                walkOwedDate = nil
                return .walk
            }
            walkBlockedByWeather = true
        }

        // Rotation has at most one walk slot, so this finds a non-walk exercise
        // within two steps.
        while true {
            let exercise = rotation[rotationIndex % rotation.count]
            rotationIndex += 1

            guard case .walk = exercise else { return exercise }

            // Don't repeat the walk once it's actually been completed today.
            if isWalkDoneToday() { continue }

            // Too cold or wet: substitute the next exercise, but keep the walk owed
            // so it comes back once conditions improve.
            if walkBlockedByWeather { continue }
            if await WeatherService.shared.isWalkWeatherOK() { return .walk }
            walkOwedDate = Date()
            continue
        }
    }

    private func isWalkOwedToday() -> Bool {
        guard let d = walkOwedDate else { return false }
        return Calendar.current.isDateInToday(d)
    }

    // The walk is "done" only once a walk has been confirmed (logged) today —
    // skipping or dismissing the panel does not count.
    private func isWalkDoneToday() -> Bool {
        DataStore.shared.entries.contains {
            $0.exercise == "walk" && Calendar.current.isDateInToday($0.timestamp)
        }
    }
}
