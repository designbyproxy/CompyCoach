import Foundation

// MARK: - ActiveCountdown

// Counts down *active* time until the next nudge. Pure logic, no system calls — the
// TriggerEngine samples the world every few seconds and feeds it in via step().
//
// The countdown freezes while you're on a call, away from the keyboard, asleep, or
// already looking at a panel, and picks up where it left off afterwards. There is only
// ever one countdown, so a long call can't leave a held nudge plus a fresh timer that
// then fire back-to-back.

struct ActiveCountdown {
    enum Status: Equatable {
        case running
        case pausedCall      // camera / mic / screen sharing in use
        case pausedAway      // no input for `awayThreshold`
        case showingPanel    // a nudge is on screen
    }

    // No input for this long counts as away. Long enough that reading or watching
    // something still counts as being at the desk; the idle stretch is refunded either way.
    static let awayThreshold: TimeInterval = 10 * 60

    // A nudge that comes due after this much idle time is held until you're back,
    // so it doesn't land on an empty desk during the long away threshold.
    static let dueIdleHold: TimeInterval = 2 * 60

    // The first time a pause ends close to a nudge, at least this much active time
    // remains, so you're not ambushed the moment you hang up or sit back down. Only
    // once per interval, so popping in and out can't keep pushing a due nudge back.
    static let resumeGrace: TimeInterval = 2 * 60

    // A gap between samples longer than this (sleep, a stalled main thread) is
    // treated as a pause rather than as active time.
    let maxSampleGap: TimeInterval

    private(set) var remaining: TimeInterval
    private(set) var status: Status = .running
    private var lastSample: Date

    // Active time counted since the countdown last (re)entered .running. When we
    // discover the user went away, the idle stretch we already counted is refunded
    // from this.
    private var countedSinceResume: TimeInterval = 0

    // Idle time at the last counted sample. If the Mac then sleeps before the away
    // threshold, this is the idle stretch to refund on wake.
    private var lastIdle: TimeInterval = 0

    // Whether this interval has already used its resume grace.
    private var graceGiven = false

    init(remaining: TimeInterval, now: Date, maxSampleGap: TimeInterval) {
        self.remaining = remaining
        self.lastSample = now
        self.maxSampleGap = maxSampleGap
    }

    /// Starts a fresh interval (after a nudge fires, or on "Skip Next").
    mutating func restart(remaining: TimeInterval) {
        self.remaining = remaining
        countedSinceResume = 0
        graceGiven = false
    }

    /// Feeds one sample of the world. Returns true when a nudge is due now.
    mutating func step(now: Date, idleSeconds: TimeInterval, inCall: Bool, panelShowing: Bool) -> Bool {
        let gap = max(0, now.timeIntervalSince(lastSample))
        lastSample = now

        // Away after the full threshold, or sooner if a nudge is about to come due (and
        // then until you're back, so the refunded time doesn't count down on an empty desk).
        let away = idleSeconds >= Self.awayThreshold
            || (idleSeconds >= Self.dueIdleHold && (status == .pausedAway || remaining <= gap))

        let next: Status
        if panelShowing   { next = .showingPanel }
        else if inCall    { next = .pausedCall }
        else if away      { next = .pausedAway }
        else              { next = .running }

        // Paused (or staying paused): nothing is counted for this gap.
        guard next == .running else {
            if status == .running, next == .pausedAway {
                // The user stopped touching the machine `idleSeconds` ago, but we only
                // notice at the threshold. Give back the idle time already counted.
                let countedIdle = max(0, idleSeconds - gap)
                remaining += min(countedIdle, countedSinceResume)
            }
            status = next
            countedSinceResume = 0
            return false
        }

        // Resuming from a pause or a sleep-sized gap: don't count the gap, and make
        // sure there's a little breathing room before the next nudge.
        if status != .running || gap > maxSampleGap {
            if status == .running {
                // Slept straight from running: refund the idle stretch before the sleep,
                // which the away check never got to.
                remaining += min(lastIdle, countedSinceResume)
            }
            status = .running
            countedSinceResume = 0
            lastIdle = idleSeconds
            if !graceGiven, remaining < Self.resumeGrace {
                remaining = Self.resumeGrace
                graceGiven = true
            }
            return false
        }

        remaining -= gap
        countedSinceResume += gap
        lastIdle = idleSeconds
        if remaining <= 0 {
            remaining = 0
            return true
        }
        return false
    }
}
