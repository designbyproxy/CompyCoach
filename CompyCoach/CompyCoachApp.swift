import SwiftUI
import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            DataStore.shared.load()
            TriggerEngine.shared.start()
        }
    }
}

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

        Divider()

        // Countdown of active time — freezes during calls, away time, and sleep
        Text(countdownLine)

        Divider()

        Button("Skip Next") {
            DataStore.shared.logSkip()
            TriggerEngine.shared.skipNext()
        }

        Button("Quit CompyCoach") {
            NSApplication.shared.terminate(nil)
        }

        #if DEBUG
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
