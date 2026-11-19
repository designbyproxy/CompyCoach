import AppKit
import SwiftUI

// MARK: - Window

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private init() {}

    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "About CompyCoach"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = DBP.nsGround
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: AboutView())
            w.center()
            window = w
        }

        // Menu bar apps aren't frontmost, so bring the app forward with the window.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

private struct AboutView: View {
    private static let siteURL = URL(string: "https://designbyproxy.com")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Placeholder mark until the DBP logo lands.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .padding(.bottom, 24)

            Text("CompyCoach")
                .font(DBPFont.display(44, weight: 800))
                .textCase(.uppercase)
                .foregroundStyle(DBP.ink)

            Text(version)
                .font(DBPFont.mono(12, medium: true))
                .tracking(12 * 0.1)
                .textCase(.uppercase)
                .foregroundStyle(DBP.muted)
                .padding(.top, 8)

            Text("Exercise breaks that take over your screen and get harder as you keep up.")
                .font(DBPFont.body(15))
                .foregroundStyle(DBP.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            Rectangle()
                .fill(DBP.rule)
                .frame(height: 1)
                .padding(.vertical, 24)

            Text("Designed by Proxy")
                .font(DBPFont.mono(12, medium: true))
                .tracking(12 * 0.1)
                .textCase(.uppercase)
                .foregroundStyle(DBP.muted)

            Button {
                NSWorkspace.shared.open(Self.siteURL)
            } label: {
                HStack(spacing: 6) {
                    Text("designbyproxy.com")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .buttonStyle(DBPGhostButtonStyle(height: 44, fontSize: 18))
            .help("Opens designbyproxy.com in your browser")
        }
        .padding(.horizontal, 32)
        .padding(.top, 48)   // clears the transparent title bar
        .padding(.bottom, 24)
        .frame(width: 360, alignment: .leading)
        .background(DBP.ground)
    }
}
