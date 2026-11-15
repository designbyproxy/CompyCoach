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

    // No input for this long counts as away.
    static let awayThreshold: TimeInterval = 3 * 60

    // After any pause ends, at least this much active time remains before a nudge,
    // so you're never ambushed the moment you hang up or sit back down.
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

    init(remaining: TimeInterval, now: Date, maxSampleGap: TimeInterval) {
        self.remaining = remaining
        self.lastSample = now
        self.maxSampleGap = maxSampleGap
    }

    /// Starts a fresh interval (after a nudge fires, or on "Skip Next").
    mutating func restart(remaining: TimeInterval) {
        self.remaining = remaining
        countedSinceResume = 0
    }

    /// Feeds one sample of the world. Returns true when a nudge is due now.
    mutating func step(now: Date, idleSeconds: TimeInterval, inCall: Bool, panelShowing: Bool) -> Bool {
        let gap = max(0, now.timeIntervalSince(lastSample))
        lastSample = now

        let next: Status
        if panelShowing                        { next = .showingPanel }
        else if inCall                         { next = .pausedCall }
        else if idleSeconds >= Self.awayThreshold { next = .pausedAway }
        else                                   { next = .running }

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
            status = .running
            countedSinceResume = 0
            remaining = max(remaining, Self.resumeGrace)
            return false
        }

        remaining -= gap
        countedSinceResume += gap
        if remaining <= 0 {
            remaining = 0
            return true
        }
        return false
    }
}
