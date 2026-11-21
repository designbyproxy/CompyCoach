import AppKit
import SwiftUI

// MARK: - Panel window

private final class InterruptionNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) {}  // block cmd-W
}

// MARK: - Panel manager

@MainActor
final class InterruptionPanelManager {
    static let shared = InterruptionPanelManager()
    private init() {}

    private var panel: InterruptionNSPanel?
    private var hostingController: NSHostingController<InterruptionView>?
    // Set from the first Confirm / "not now" until the fade-out finishes, so a double
    // click or a second Return during the fade can't log the exercise twice.
    private var dismissing = false

    var isShowing: Bool { panel != nil }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(exercise: Exercise) {
        guard panel == nil else { return }

        let target = DataStore.shared.currentTarget(for: exercise)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let p = InterruptionNSPanel(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            // .nonactivatingPanel lets the panel become the key window — and so take
            // keyboard input — even when macOS (14+) declines to activate the app.
            // Without it the reps field looks focused but keystrokes still go to
            // whatever app was frontmost. Must be set at init, not afterwards.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .screenSaver
        p.isOpaque = false  // so the panel can fade up over the desktop
        p.backgroundColor = DBP.nsGround
        p.alphaValue = 0
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovable = false
        p.hidesOnDeactivate = false

        let onConfirm: (Int?) -> Void = { [weak self] logged in
            guard let self, !self.dismissing else { return }
            DataStore.shared.append(exercise: exercise, target: target, logged: logged)
            self.dismiss()
        }

        let onNotNow: () -> Void = { [weak self] in
            guard let self, !self.dismissing else { return }
            TriggerEngine.shared.deferWalk()
            self.dismiss()
        }

        let view = InterruptionView(exercise: exercise, target: target,
                                    weather: WeatherService.shared.lastReading,
                                    notNowLabel: TriggerEngine.shared.isFinalWalkOfferToday
                                        ? "Skip for today" : "I can't right now",
                                    onConfirm: onConfirm, onNotNow: onNotNow)
        let controller = NSHostingController(rootView: view)
        p.contentViewController = controller
        // Set frame after contentViewController so AppKit can't resize the window
        // down to the SwiftUI view's ideal size before the frame is applied.
        p.setFrame(screen.frame, display: true)
        hostingController = controller
        panel = p

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        p.makeKeyAndOrderFront(nil)
        p.makeKey()

        // Fade up over the desktop instead of cutting to black.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.74
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard let p = panel, !dismissing else { return }
        dismissing = true
        p.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                p.orderOut(nil)
                if self?.panel === p {
                    self?.panel = nil
                    self?.hostingController = nil
                    self?.dismissing = false
                }
            }
        })
    }
}

// MARK: - Grid

/// The takeover's 12-column grid, sized from a 1440 × 900 reference: 96pt margins, 24pt gutters,
/// a 72pt lead size and a 389pt hero, all scaled to the screen.
struct TakeoverMetrics {
    let unit: CGFloat
    let width: CGFloat

    init(size: CGSize) {
        unit = min(size.width / 1440, size.height / 900)
        width = size.width
    }

    var margin: CGFloat { 96 * unit }
    var gutter: CGFloat { 24 * unit }
    var column: CGFloat { (width - 2 * margin - 11 * gutter) / 12 }
    func span(_ n: Int) -> CGFloat { column * CGFloat(n) + gutter * CGFloat(n - 1) }

    var lead: CGFloat { 72 * unit }           // lead-in, companion, question
    var entry: CGFloat { lead * 1.6 }        // the typed count
    var hero: CGFloat { 389 * unit }
    var buttonHeight: CGFloat { 64 * unit }
    var buttonFont: CGFloat { 24 * unit }
    var band: CGFloat { margin }              // timer band lives in the bottom margin
    var label: CGFloat { 18 * unit }
}

// MARK: - SwiftUI view

struct InterruptionView: View {
    let exercise: Exercise
    let target: Int
    let weather: WeatherService.Reading?
    let notNowLabel: String
    let onConfirm: (_ logged: Int?) -> Void
    let onNotNow: () -> Void

    @State private var appeared = false
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let m = TakeoverMetrics(size: geo.size)
            ZStack(alignment: .bottomLeading) {
                DBP.ground

                composition(m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(m.margin)

                if exercise.isTimed {
                    TimerBand(seconds: target, metrics: m) { onConfirm(target) }
                        .reveal(appeared, delay: 0.7, reduceMotion: reduceMotion)
                }
            }
        }
        .ignoresSafeArea()
        .onExitCommand {}
        .onAppear {
            appeared = true
            guard exercise.requiresRepInput else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { inputFocused = true }
        }
        // Re-focus the reps field whenever the panel becomes key — covers the panel
        // turning key after onAppear, and clicking back onto it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard exercise.requiresRepInput,
                  (note.object as? NSWindow)?.level == .screenSaver else { return }
            inputFocused = true
        }
    }

    // MARK: Compositions

    @ViewBuilder
    private func composition(_ m: TakeoverMetrics) -> some View {
        if exercise.requiresRepInput {
            repsSplit(m)
        } else if case .walk = exercise {
            VStack(alignment: .leading, spacing: m.lead * 0.45) {
                leadIn(m)
                heroRow(m)
                HStack(spacing: m.gutter) {
                    Button("Confirm") { onConfirm(nil) }
                        .buttonStyle(DBPPrimaryButtonStyle(height: m.buttonHeight, fontSize: m.buttonFont))
                        .keyboardShortcut(.defaultAction)
                        .frame(width: m.span(4))
                    Button(notNowLabel, action: onNotNow)
                        .buttonStyle(DBPOutlineButtonStyle(height: m.buttonHeight, fontSize: m.buttonFont))
                        .frame(width: m.span(4))
                }
                .padding(.top, m.lead * 0.4)
                .reveal(appeared, delay: 1.0, reduceMotion: reduceMotion)
            }
        } else {
            VStack(alignment: .leading, spacing: m.lead * 0.45) {
                leadIn(m)
                heroRow(m)
            }
        }
    }

    /// Reps: lead-in and hero on columns 1–6; the question, count and CONFIRM on columns 7–12.
    /// The question's top lines up with the lead-in and CONFIRM's bottom with the hero's baseline.
    private func repsSplit(_ m: TakeoverMetrics) -> some View {
        HStack(alignment: .top, spacing: m.gutter) {
            VStack(alignment: .leading, spacing: m.lead * 0.45) {
                leadIn(m)
                heroRow(m)
            }
            .frame(width: m.span(6), alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: m.lead * 0.22) {
                    CapText(text: "How many", size: m.lead)
                    CapText(text: "did you do?", size: m.lead)
                }
                Spacer(minLength: m.gutter)
                VStack(alignment: .leading, spacing: m.gutter * 1.5) {
                    repsEntry(m)
                    Button("Confirm", action: confirmReps)
                        .buttonStyle(DBPPrimaryButtonStyle(height: m.buttonHeight, fontSize: m.buttonFont))
                        .disabled(Int(inputText) == nil)
                }
            }
            .frame(width: m.span(6), alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .reveal(appeared, delay: 0.95, reduceMotion: reduceMotion)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func leadIn(_ m: TakeoverMetrics) -> some View {
        CapText(text: exercise.leadIn, size: m.lead)
            .reveal(appeared, delay: 0.22, reduceMotion: reduceMotion)
    }

    /// The extruded hero with its stacked companion, sitting on the hero's baseline.
    private func heroRow(_ m: TakeoverMetrics) -> some View {
        HStack(alignment: .bottom, spacing: m.gutter * 1.5) {
            ExtrudedText(text: exercise.hero(target: target), size: m.hero)
            let lines = companionLines
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: m.lead * 0.22) {
                    ForEach(lines, id: \.self) { CapText(text: $0, size: m.lead) }
                }
                .reveal(appeared, delay: 0.8, reduceMotion: reduceMotion)
            }
        }
    }

    /// The walk's companion is the weather: feels-like temperature, then the conditions.
    private var companionLines: [String] {
        guard case .walk = exercise else { return exercise.companion }
        guard let r = weather else { return [] }
        var lines = ["\(Int(r.feelsLikeF.rounded()))°"]
        var current = "and"
        for word in WeatherService.describe(r.weatherCode).split(separator: " ") {
            if current.count + 1 + word.count > 10 {
                lines.append(current)
                current = String(word)
            } else {
                current += " " + word
            }
        }
        lines.append(current)
        return lines
    }

    // MARK: Reps entry

    private func repsEntry(_ m: TakeoverMetrics) -> some View {
        let font = DBPFont.display(m.entry, weight: 700, tabular: true)
        return ZStack(alignment: .leading) {
            // macOS ignores styling on a TextField prompt, so the "0" placeholder is drawn underneath.
            if inputText.isEmpty {
                Text("0").font(font).foregroundStyle(DBP.inert).allowsHitTesting(false)
            }
            TextField("", text: $inputText)
                .font(font)
                .foregroundStyle(DBP.ink)
                .tint(DBP.light)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { if Int(inputText) != nil { confirmReps() } }
                .onChange(of: inputText) { value in
                    let digits = String(value.filter(\.isNumber).prefix(3))
                    if digits != value { inputText = digits }
                }
        }
        .padding(.bottom, m.unit * 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(inputFocused ? DBP.light : DBP.ruleHover)
                .frame(height: 1)
                .animation(DBP.press, value: inputFocused)
        }
    }

    private func confirmReps() {
        guard let n = Int(inputText) else { return }
        onConfirm(n)
    }
}

// MARK: - Timer band

/// The clock for timed exercises, in the bottom margin. A thin cream line grows left to right while
/// counting; at zero it drops open into the full band and CONFIRM arrives on it.
private struct TimerBand: View {
    let seconds: Int
    let metrics: TakeoverMetrics
    let onConfirm: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var done = false
    @State private var opened = false
    @State private var showButton = false

    /// The count starts once the entrance has settled.
    private static let startDelay = 1.5

    var body: some View {
        let m = metrics
        TimelineView(.animation(paused: start == nil || done)) { timeline in
            let progress = progress(at: timeline.date)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(DBP.ink)
                    .scaleEffect(x: opened ? 1 : progress, y: opened ? 1 : 0.035, anchor: .topLeading)

                Text(label(progress))
                    .font(DBPFont.mono(m.label, medium: true))
                    .tracking(m.label * 0.1)
                    .textCase(.uppercase)
                    .foregroundStyle(DBP.ink)
                    .blendMode(.difference)  // light on the ground, dark once the band fills under it
                    .frame(maxHeight: .infinity)
                    .padding(.leading, m.margin)

                HStack {
                    Spacer()
                    Button("Confirm", action: onConfirm)
                        .buttonStyle(DBPOutlineButtonStyle(height: m.buttonHeight, fontSize: m.buttonFont, onLight: true))
                        .keyboardShortcut(.defaultAction)
                        .frame(width: m.span(3))
                        .disabled(!showButton)
                        .opacity(showButton ? 1 : 0)
                        .offset(y: showButton || reduceMotion ? 0 : m.unit * 18)
                        .animation(reduceMotion ? DBP.reducedMotion : DBP.settle, value: showButton)
                }
                .frame(maxHeight: .infinity)
                .padding(.trailing, m.margin)
            }
            .compositingGroup()
        }
        .frame(height: m.band)
        .frame(maxWidth: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.startDelay) { start = Date() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.startDelay + Double(seconds)) { finish() }
        }
    }

    private func progress(at date: Date) -> CGFloat {
        guard let start else { return 0 }
        return CGFloat(min(1, max(0, date.timeIntervalSince(start) / Double(max(seconds, 1)))))
    }

    private func label(_ progress: CGFloat) -> String {
        if done { return "Done" }
        let left = Int((Double(seconds) * Double(1 - progress)).rounded(.up))
        return left == 1 ? "1 second" : "\(left) seconds"
    }

    private func finish() {
        done = true
        withAnimation(reduceMotion ? DBP.reducedMotion : DBP.carry) { opened = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.35)) { showButton = true }
    }
}

// MARK: - Reveal

private extension View {
    /// Supporting elements only fade in, so the hero's extrusion is the one moving moment.
    func reveal(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .animation(reduceMotion ? DBP.reducedMotion : DBP.carry.delay(delay), value: shown)
    }
}
