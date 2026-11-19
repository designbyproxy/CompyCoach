import Foundation

// MARK: - LogEntry

struct LogEntry: Codable {
    let timestamp: Date
    let exercise: String   // logKey
    let target: Int
    let logged: Int?       // nil for non-rep exercises
    let hit: Bool
}

// MARK: - DataStore

@MainActor
final class DataStore: ObservableObject {
    static let shared = DataStore()
    private init() {}

    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var targets: [String: Int] = DataStore.defaultTargets

    // MARK: Defaults / constants

    static let defaultTargets: [String: Int] = [
        "squats":       10,
        "pushups":      8,
        "situps":       12,
        "standStretch": 45,
        "eyeRelax":     20,
        "walk":         1
    ]

    static let minimumTargets: [String: Int] = [
        "squats":       5,
        "pushups":      4,
        "situps":       5,
        "standStretch": 20,
        "eyeRelax":     20,
        "walk":         1
    ]

    /// Keys excluded from adaptive progression.
    static let fixedExercises: Set<String> = ["standStretch", "eyeRelax", "walk"]

    // MARK: File paths

    private var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CompyCoach", isDirectory: true)
    }

    private var logFileURL: URL {
        appSupportURL.appendingPathComponent("log.json")
    }

    private var targetsFileURL: URL {
        appSupportURL.appendingPathComponent("targets.json")
    }

    // MARK: ISO-8601 decoder/encoder helpers

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    // MARK: load()

    func load() {
        // Ensure directory exists
        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupportURL.path) {
            try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        }

        // Load targets — merge saved over defaults so new keys always get defaults
        var merged = DataStore.defaultTargets
        if let data = try? Data(contentsOf: targetsFileURL),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            for (k, v) in saved { merged[k] = v }
        }
        // Fixed exercises must never deviate from their defaults (saved values could be stale)
        for key in DataStore.fixedExercises {
            if let def = DataStore.defaultTargets[key] { merged[key] = def }
        }
        targets = merged

        // Load log (NDJSON: one JSON object per line)
        entries = []
        guard let raw = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let decoder = makeDecoder()
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(LogEntry.self, from: data) else { continue }
            entries.append(entry)
        }
    }

    // MARK: currentTarget(for:)

    func currentTarget(for exercise: Exercise) -> Int {
        let key = exercise.logKey
        return targets[key] ?? DataStore.defaultTargets[key] ?? 1
    }

    // MARK: append(exercise:target:logged:)

    func append(exercise: Exercise, target: Int, logged: Int?) {
        let hit: Bool
        if let logged = logged {
            hit = logged >= target
        } else {
            hit = true
        }
        let entry = LogEntry(
            timestamp: Date(),
            exercise: exercise.logKey,
            target: target,
            logged: logged,
            hit: hit
        )
        entries.append(entry)
        writeEntry(entry)

        let key = exercise.logKey
        if !DataStore.fixedExercises.contains(key), !targetChangedToday(key) {
            recalculate(for: key)
            writeTargets()
        }
    }

    /// Targets move at most once a day, so a run of good breaks can't compound a 10% bump
    /// several times over. The first entry logged today records the target the day started
    /// with; if the current target differs, it has already moved today (or was reset by hand,
    /// which also holds until tomorrow).
    private func targetChangedToday(_ key: String) -> Bool {
        guard let first = entries.first(where: {
            $0.exercise == key && Calendar.current.isDateInToday($0.timestamp)
        }) else { return false }
        return first.target != (targets[key] ?? DataStore.defaultTargets[key] ?? 1)
    }

    // MARK: Private: recalculate(for:)

    private func recalculate(for key: String) {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let recent = entries.filter { $0.exercise == key && $0.timestamp >= sevenDaysAgo }
        guard !recent.isEmpty else { return }

        let count = recent.count
        let hits = recent.filter { $0.hit }.count
        let hitRate = Double(hits) / Double(count)

        let current = targets[key] ?? DataStore.defaultTargets[key] ?? 1
        let floor = DataStore.minimumTargets[key] ?? 1

        if hitRate >= 0.8 {
            let newTarget = max(current + 1, Int((Double(current) * 1.1).rounded()))
            targets[key] = newTarget
        } else if hitRate <= 0.5 {
            let raw = Int((Double(current) * 0.9).rounded())
            let newTarget = max(floor, min(current - 1, raw))
            targets[key] = newTarget
        }
        // 50–80%: hold (no change)
    }

    // MARK: Private: writeEntry(_:)

    private func writeEntry(_ entry: LogEntry) {
        let fm = FileManager.default
        let path = logFileURL.path

        // Create file if it doesn't exist
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }

        guard let encoded = try? makeEncoder().encode(entry),
              var line = String(data: encoded, encoding: .utf8) else { return }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return }

        // The throwing FileHandle APIs report a full disk or I/O error as a Swift error;
        // the legacy seekToEndOfFile()/write(_:) raise an Objective-C exception and crash.
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: lineData)
        } catch {
            // Drop this one entry rather than take the app down; it's still in memory.
        }
    }

    // MARK: Private: writeTargets()

    private func writeTargets() {
        guard let data = try? JSONEncoder().encode(targets) else { return }
        try? data.write(to: targetsFileURL, options: .atomic)
    }

    // MARK: logSkip()

    func logSkip() {
        let entry = LogEntry(timestamp: Date(), exercise: "skip", target: 0, logged: nil, hit: false)
        entries.append(entry)
        writeEntry(entry)
        // No recalculate or writeTargets — skips have no adaptive effect.
    }

    // MARK: DEBUG

    #if DEBUG
    /// Checks the progression math against fake history, starting from default targets,
    /// then puts the real entries and targets back so nothing fake is ever saved.
    func seedTestData() {
        let savedEntries = entries, savedTargets = targets
        defer { entries = savedEntries; targets = savedTargets }
        targets = DataStore.defaultTargets
        entries = []

        let now = Date()
        func daysAgo(_ n: Int) -> Date {
            now.addingTimeInterval(-Double(n) * 24 * 60 * 60)
        }

        var synthetic: [LogEntry] = []

        // squats: 6 hits + 1 miss (target 10) → hitRate 85.7% → should increase
        for i in 0..<6 {
            synthetic.append(LogEntry(timestamp: daysAgo(i), exercise: "squats", target: 10, logged: 10, hit: true))
        }
        synthetic.append(LogEntry(timestamp: daysAgo(6), exercise: "squats", target: 10, logged: 5, hit: false))

        // pushups: 3 hits + 4 misses (target 8) → hitRate 42.9% → should decrease
        for i in 0..<3 {
            synthetic.append(LogEntry(timestamp: daysAgo(i), exercise: "pushups", target: 8, logged: 8, hit: true))
        }
        for i in 3..<7 {
            synthetic.append(LogEntry(timestamp: daysAgo(i), exercise: "pushups", target: 8, logged: 3, hit: false))
        }

        // standStretch: 5 hits + 2 misses (target 45) → hitRate 71.4% → hold
        for i in 0..<5 {
            synthetic.append(LogEntry(timestamp: daysAgo(i), exercise: "standStretch", target: 45, logged: nil, hit: true))
        }
        for i in 5..<7 {
            synthetic.append(LogEntry(timestamp: daysAgo(i), exercise: "standStretch", target: 45, logged: nil, hit: false))
        }

        entries = synthetic

        // Recalculate adaptive targets
        recalculate(for: "squats")
        recalculate(for: "pushups")
        recalculate(for: "standStretch")

        print("DataStore.seedTestData results:")
        print("  squats target:       \(targets["squats"] ?? -1)   (expected 11)")
        print("  pushups target:      \(targets["pushups"] ?? -1)   (expected 7)")
        print("  standStretch target: \(targets["standStretch"] ?? -1) (expected 45 — hold)")
    }
    #endif
}
