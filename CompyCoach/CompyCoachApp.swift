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
    @State private var launchAtLogin: Bool

    init() {
        store = DataStore.shared
        engine = TriggerEngine.shared
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

        // Countdown — refreshes every minute while the menu is open
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            Text(countdown(at: ctx.date))
        }

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

    private func target(_ key: String) -> Int {
        store.targets[key] ?? DataStore.defaultTargets[key] ?? 0
    }

    private func countdown(at now: Date) -> String {
        let secs = engine.nextFireDate.timeIntervalSince(now)
        guard secs > 60 else { return "Next: <1m" }
        return "Next: \(Int(secs / 60))m"
    }
}
