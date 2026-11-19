import AppKit
import SwiftUI

// Optional 10-second warning before a nudge takes over the screen: a small chip in the top-right
// corner, under the menu bar, counting down ("SQUATS IN 7"). Off by default; toggled from the menu.

@MainActor
final class HeadsUpController {
    static let shared = HeadsUpController()
    private init() {}

    static let defaultsKey = "headsUpEnabled"
    static let leadTime = 10

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
    var isShowing: Bool { panel != nil }

    private var panel: NSPanel?

    /// Shows the chip for `leadTime` seconds, then removes it and runs `then`.
    func show(for exercise: Exercise, then: @escaping @MainActor () -> Void) {
        guard panel == nil else { return }

        let end = Date().addingTimeInterval(TimeInterval(Self.leadTime))
        let host = NSHostingController(rootView: HeadsUpChip(label: "\(exercise.displayName) in", end: end))
        let size = host.view.fittingSize

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame  // below the menu bar
        let p = NSPanel(contentRect: NSRect(x: visible.maxX - size.width - 16,
                                            y: visible.maxY - size.height - 12,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentViewController = host
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(Self.leadTime)) { [weak self] in
            p.orderOut(nil)
            if self?.panel === p { self?.panel = nil }
            then()
        }
    }
}

private struct HeadsUpChip: View {
    let label: String
    let end: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let left = max(1, Int(end.timeIntervalSince(timeline.date).rounded(.up)))
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(DBPFont.mono(13, medium: true))
                    .tracking(13 * 0.1)
                    .textCase(.uppercase)
                    .foregroundStyle(DBP.ink)
                Text("\(left)")
                    .font(DBPFont.display(28, weight: 800, tabular: true))
                    .foregroundStyle(DBP.ink)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: DBP.radiusSM).fill(DBP.surface))
            .overlay(RoundedRectangle(cornerRadius: DBP.radiusSM).strokeBorder(DBP.ruleStrong))
        }
    }
}
