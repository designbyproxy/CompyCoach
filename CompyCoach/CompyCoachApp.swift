import SwiftUI
import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            #if DEBUG
            // scripts/make-screenshots.sh launches the app with `-screenshot <name>` to put one
            // screen up for capture. Saved data stays unloaded so the screens show a new user's
            // starting targets, and the nudge timer stays off so nothing else appears.
            if let name = UserDefaults.standard.string(forKey: "screenshot") {
                ScreenshotMode.show(name)
                return
            }
            #endif
            DataStore.shared.load()
            TriggerEngine.shared.start()
        }
    }
}

#if DEBUG
@MainActor
enum ScreenshotMode {
    static var isActive: Bool { UserDefaults.standard.string(forKey: "screenshot") != nil }

    static func show(_ name: String) {
        let exercises: [String: Exercise] = [
            "squats": .squats, "pushups": .pushups, "situps": .situps,
            "stretch": .standStretch, "eyes": .eyeRelax, "walk": .walk,
        ]
        if name == "about" {
            AboutWindowController.shared.show()
        } else if name == "menu" {
            // Shows a sample home (never saved) and opens the menu bar menu.
            WeatherService.shared.useSampleHome()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.windows.lazy.compactMap { $0.contentView.flatMap(statusButton(in:)) }
                    .first?.performClick(nil)
            }
        } else if let exercise = exercises[name] {
            if exercise == .walk { WeatherService.shared.useSampleReading() }
            InterruptionPanelManager.shared.show(exercise: exercise)
        } else {
            print("Unknown screenshot \"\(name)\". Try: about, menu, \(exercises.keys.sorted().joined(separator: ", "))")
            NSApp.terminate(nil)
        }
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap(statusButton(in:)).first
    }
}
#endif

@main
struct CompyCoachApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("CompyCoach", image: "MenuBarIcon") {
            MenuBarContent()
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - MenuBarContent

private struct MenuBarContent: View {
    @ObservedObject private var store: DataStore
    @ObservedObject private var engine: TriggerEngine
    @ObservedObject private var weather: WeatherService
    @State private var launchAtLogin: Bool
    @AppStorage(HeadsUpController.defaultsKey) private var headsUp = false

    init() {
        store = DataStore.shared
        engine = TriggerEngine.shared
        weather = WeatherService.shared
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled
                                          || SMAppService.mainApp.status == .requiresApproval)
    }

    var body: some View {
        // Header
        Text("CompyCoach by Proxy")
        Text(todaySummary)

        Divider()

        // Targets
        Text("Current Targets")
        Text("Squats · \(target("squats")) reps")
        Text("Push-ups · \(target("pushups")) reps")
        Text("Sit-ups · \(target("situps")) reps")
        Text("Stand/Stretch · \(target("standStretch")) sec")

        Divider()

        // Weather — decides whether walks are suggested
        Text(weatherLine)
            .onAppear { Task { _ = await WeatherService.shared.currentReading() } }
        Button(weather.homeZIP == nil ? "Set Home ZIP for Walk Weather…" : "Change Home ZIP…") {
            // Let the menu finish closing before putting up a modal dialog.
            DispatchQueue.main.async { HomeZIPPrompt.run() }
        }

        Divider()

        // Login item
        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { isOn in
                do {
                    if isOn {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    // Silently snap back to actual system state on failure
                    // (most common cause: app not in /Applications)
                }
                let status = SMAppService.mainApp.status
                launchAtLogin = status == .enabled || status == .requiresApproval
            }

        // Optional 10-second warning chip before a nudge takes over the screen (off by default)
        Toggle("10-Second Heads-Up", isOn: $headsUp)

        Divider()

        // Countdown of active time — freezes during calls, away time, and sleep
        Text(countdownLine)

        Divider()

        Button("Skip Next") {
            DataStore.shared.logSkip()
            TriggerEngine.shared.skipNext()
        }

        Divider()

        Button("About CompyCoach") {
            // Let the menu finish closing before bringing a window forward.
            DispatchQueue.main.async { AboutWindowController.shared.show() }
        }

        Button("Check for Updates…") {
            DispatchQueue.main.async { UpdateCheck.run() }
        }

        Button("Quit CompyCoach") {
            NSApplication.shared.terminate(nil)
        }

        #if DEBUG
        if !ScreenshotMode.isActive {
        Divider()
        Button("Trigger Panel") {
            InterruptionPanelManager.shared.show(exercise: .squats)
        }
        Button("Trigger Sit-ups") {
            InterruptionPanelManager.shared.show(exercise: .situps)
        }
        Button("Trigger Stretch") {
            InterruptionPanelManager.shared.show(exercise: .standStretch)
        }
        Button("Trigger Walk") {
            InterruptionPanelManager.shared.show(exercise: .walk)
        }
        Button("Trigger Eye Relax") {
            InterruptionPanelManager.shared.show(exercise: .eyeRelax)
        }
        Button("Trigger Heads-Up → Squats") {
            HeadsUpController.shared.show(for: .squats) {
                InterruptionPanelManager.shared.show(exercise: .squats)
            }
        }
        Button("Trigger Walk (weather-gated)") {
            Task { @MainActor in
                let ok = await WeatherService.shared.isWalkWeatherOK()
                print("Walk weather OK: \(ok) — \(WeatherService.shared.lastReading?.summary ?? "no reading")")
                InterruptionPanelManager.shared.show(exercise: ok ? .walk : .standStretch)
            }
        }
        Button("Seed Test Data") {
            DataStore.shared.seedTestData()
        }
        }
        #endif
    }

    private var todaySummary: String {
        let today = store.entries.filter {
            Calendar.current.isDateInToday($0.timestamp) && $0.exercise != "skip"
        }
        guard !today.isEmpty else { return "No challenges yet today." }
        let hit = today.filter { $0.hit }.count
        return "Today: \(hit)/\(today.count) hit"
    }

    private var weatherLine: String {
        guard let zip = weather.homeZIP else { return "Walk weather: no home ZIP set" }
        let place = weather.homePlaceName.map { "\($0) (\(zip))" } ?? zip
        guard let r = weather.lastReading else { return "Home: \(place)" }
        return "\(place): \(r.summary) — \(r.isWalkable ? "walks on" : "no walks")"
    }

    private func target(_ key: String) -> Int {
        store.targets[key] ?? DataStore.defaultTargets[key] ?? 0
    }

    private var countdownLine: String {
        let mins = engine.remaining < 60 ? "<1m" : "\(Int(engine.remaining / 60))m"
        switch engine.status {
        case .running:      return "Next: \(mins)"
        case .pausedCall:   return "Paused — on a call (\(mins) left)"
        case .pausedAway:   return "Paused — away (\(mins) left)"
        case .showingPanel: return "Nudge in progress"
        }
    }
}

// MARK: - Home ZIP prompt

@MainActor
enum HomeZIPPrompt {
    static func run() {
        let alert = NSAlert()
        alert.messageText = "Home ZIP for Walk Weather"
        alert.informativeText = "CompyCoach skips walks when it feels colder than \(Int(WeatherService.minWalkTempF))°F, it's precipitating, "
            + "or there's a \(WeatherService.maxRainChancePct)%+ chance of rain in the next hour at home. "
            + "Your ZIP is stored only on this Mac. Leave blank to turn the weather check off."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = WeatherService.shared.homeZIP ?? ""
        field.placeholderString = "ZIP / postal code"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let zip = field.stringValue

        Task { @MainActor in
            do {
                try await WeatherService.shared.setHomeZIP(zip)
            } catch {
                let err = NSAlert()
                err.messageText = "Couldn't set home ZIP"
                err.informativeText = error.localizedDescription
                err.runModal()
            }
        }
    }
}

// MARK: - Update check

/// Asks GitHub for the latest release and offers its download page if it's newer than
/// this copy. Only runs when picked from the menu, so the app never phones home on its own.
@MainActor
enum UpdateCheck {
    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/designbyproxy/CompyCoach/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    static func run() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        Task { @MainActor in
            let alert = NSAlert()
            do {
                var req = URLRequest(url: latestReleaseAPI)
                req.timeoutInterval = 10
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

                if isNewer(latest, than: current) {
                    alert.messageText = "CompyCoach \(latest) is available"
                    alert.informativeText = "You have \(current). Download the new version, quit CompyCoach, "
                        + "and drag the new copy into Applications to replace this one. Your history and targets carry over."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    activate()
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(release.html_url)
                    }
                    return
                }
                alert.messageText = "You're up to date"
                alert.informativeText = "CompyCoach \(current) is the newest version."
            } catch {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "Check your internet connection and try again."
            }
            activate()
            alert.runModal()
        }
    }

    /// Compares dotted version numbers, so 1.0.10 is newer than 1.0.9.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
