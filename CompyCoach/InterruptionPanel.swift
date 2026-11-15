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

    func show(exercise: Exercise) {
        guard panel == nil else { return }

        let target = DataStore.shared.currentTarget(for: exercise)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let p = InterruptionNSPanel(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        p.level = .screenSaver
        p.isOpaque = true
        p.backgroundColor = NSColor(red: 26/255, green: 26/255, blue: 26/255, alpha: 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovable = false
        p.hidesOnDeactivate = false

        let onConfirm: (Int?) -> Void = { [weak self] logged in
            DataStore.shared.append(exercise: exercise, target: target, logged: logged)
            self?.dismiss()
        }

        let onSkipForNow: () -> Void = { [weak self] in
            TriggerEngine.shared.deferWalk()
            self?.dismiss()
        }

        let controller = NSHostingController(rootView: InterruptionView(exercise: exercise, target: target, onConfirm: onConfirm, onSkipForNow: onSkipForNow))
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
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }
}

// MARK: - SwiftUI view

struct InterruptionView: View {
    let exercise: Exercise
    let target: Int
    let onConfirm: (_ logged: Int?) -> Void
    let onSkipForNow: () -> Void

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @State private var secondsRemaining: Int

    // Fires every second; drives the countdown for timed exercises, ignored otherwise.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let bg    = Color(red: 26/255,  green: 26/255,  blue: 26/255)
    private let cream = Color(red: 245/255, green: 240/255, blue: 232/255)
    private let red   = Color(red: 139/255, green: 26/255,  blue: 26/255)  // #8B1A1A

    init(exercise: Exercise, target: Int, onConfirm: @escaping (_ logged: Int?) -> Void, onSkipForNow: @escaping () -> Void) {
        self.exercise = exercise
        self.target = target
        self.onConfirm = onConfirm
        self.onSkipForNow = onSkipForNow
        _secondsRemaining = State(initialValue: target)
    }

    // MARK: Helpers

    private var isTimed: Bool { exercise.isTimed }

    private var isWalk: Bool {
        if case .walk = exercise { return true }
        return false
    }

    private var valid: Bool {
        if exercise.requiresRepInput { return Int(inputText) != nil }
        if isTimed { return secondsRemaining == 0 }
        return true
    }

    // Large number: remaining seconds for timed exercises, target reps otherwise.
    private var displayNumber: String {
        isTimed ? String(secondsRemaining) : String(target)
    }

    private var buttonLabel: String {
        guard isTimed else { return "CONFIRM" }
        return secondsRemaining == 0 ? "DONE" : exercise.inProgressLabel
    }

    // Fraction of time elapsed (0 → 1) for the progress bar.
    private var countdownProgress: Double {
        Double(target - secondsRemaining) / Double(max(target, 1))
    }

    // MARK: Body

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 12) {
                    Text(exercise.displayName)
                        .font(.custom("Big Shoulders", size: 72))
                        .tracking(10)
                        .foregroundStyle(cream)

                    if !exercise.quantityText.isEmpty {
                        Text(displayNumber)
                            .font(.custom("Big Shoulders", size: 160))
                            .foregroundStyle(cream)
                            .monospacedDigit()

                        Text(exercise.unitText)
                            .font(.custom("FiraSans-Regular", size: 18))
                            .tracking(6)
                            .foregroundStyle(cream.opacity(0.45))
                    }
                }

                Spacer()

                VStack(spacing: 28) {
                    if exercise.requiresRepInput {
                        Text("How many did you do?")
                            .font(.custom("FiraSans-Regular", size: 17))
                            .foregroundStyle(cream.opacity(0.6))

                        TextField("0", text: $inputText)
                            .font(.custom("FiraMono-Regular", size: 80))
                            .foregroundStyle(cream)
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.plain)
                            .frame(width: 240)
                            .focused($inputFocused)
                            .onSubmit { if valid { confirm() } }
                    } else if isTimed {
                        progressBar
                    }

                    Button(action: confirm) {
                        Text(buttonLabel)
                            .font(.custom("FiraSans-Regular", size: 17))
                            .tracking(3)
                            .foregroundStyle(cream)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(valid ? red : red.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .disabled(!valid)

                    if isWalk {
                        Button(action: onSkipForNow) {
                            Text("SKIP FOR NOW")
                                .font(.custom("FiraSans-Regular", size: 14))
                                .tracking(3)
                                .foregroundStyle(cream.opacity(0.55))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 440)

                Spacer().frame(height: 72)
            }
            .padding(.horizontal, 80)
        }
        .onExitCommand {}
        .onAppear {
            guard exercise.requiresRepInput else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                inputFocused = true
            }
        }
        .onReceive(timer) { _ in
            guard isTimed, secondsRemaining > 0 else { return }
            secondsRemaining -= 1
        }
    }

    // MARK: Progress bar (timed exercises only)

    private var progressBar: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(red.opacity(0.25))
                .frame(height: 6)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(red)
                    .frame(width: max(0, geo.size.width * countdownProgress), height: 6)
            }
            .frame(height: 6)
        }
    }

    // MARK: Confirm

    private func confirm() {
        let logged: Int?
        if exercise.requiresRepInput {
            logged = Int(inputText)
        } else if isTimed {
            logged = target  // full duration held; hit = (target >= target) = true
        } else {
            logged = nil
        }
        onConfirm(logged)
    }
}
