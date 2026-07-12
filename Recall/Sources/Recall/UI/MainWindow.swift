import AppKit
import SwiftUI

/// The app proper — an Obsidian-style shell: sidebar navigation on the left,
/// full views on the right. Opens on app-icon click.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show(engine: Engine, tab: MainTab = .home) {
        // Become a regular app while a window is open — accessory (menu-bar)
        // apps can't use native fullscreen or proper window management.
        NSApp.setActivationPolicy(.regular)

        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .recallSwitchTab, object: tab)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = "Recall"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(calibratedRed: 0.115, green: 0.105, blue: 0.095, alpha: 1)
        w.minSize = NSSize(width: 900, height: 600)
        w.collectionBehavior = [.fullScreenPrimary] // enables the green fullscreen button
        w.delegate = self
        w.contentView = NSHostingView(rootView: MainView(initialTab: tab).environmentObject(engine))
        // Open maximized to the screen's usable area, like a normal app.
        if let screen = NSScreen.main {
            w.setFrame(screen.visibleFrame, display: true)
        } else {
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    /// Back to menu-bar-only when the window closes.
    func windowWillClose(_ notification: Notification) {
        window = nil
        DispatchQueue.main.async {
            // Only drop to accessory if no other visible windows remain.
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

extension Notification.Name {
    static let recallSwitchTab = Notification.Name("recallSwitchTab")
}

enum MainTab: String, CaseIterable {
    case home = "Home"
    case graph = "Memory Graph"
    case canvas = "Canvas"
    case timeline = "Timeline"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .home: return "sparkle"
        case .graph: return "circle.hexagongrid.fill"
        case .canvas: return "scribble.variable"
        case .timeline: return "clock"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var engine: Engine
    @State var tab: MainTab

    private let bg = Color(red: 0.115, green: 0.105, blue: 0.095)
    private let sidebarBG = Color(red: 0.095, green: 0.088, blue: 0.08)
    private let amber = Color(red: 0.85, green: 0.66, blue: 0.28)
    private let cream = Color(red: 0.93, green: 0.90, blue: 0.85)

    init(initialTab: MainTab = .home) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(bg)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: .recallSwitchTab)) { note in
            if let t = note.object as? MainTab { tab = t }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text("✦").foregroundStyle(amber)
                Text("RECALL")
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .kerning(3)
                    .foregroundStyle(cream)
            }
            .padding(.top, 38)
            .padding(.bottom, 22)
            .padding(.horizontal, 18)

            ForEach(MainTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: t.icon)
                            .font(.system(size: 12))
                            .frame(width: 16)
                        Text(t.rawValue).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(tab == t ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(tab == t ? amber : cream.opacity(0.75))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    SavePanelController.shared.trigger(engine: engine)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bookmark.fill").font(.caption)
                        Text("Save a memory").font(.caption)
                        Spacer()
                        Text(engine.saveHotkeyLabel).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(amber)
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isMonitoring ? .green : .gray)
                        .frame(width: 7, height: 7)
                    Text(engine.isMonitoring ? "screen monitoring on" : "monitoring off")
                        .font(.caption2).foregroundStyle(cream.opacity(0.5))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { engine.isMonitoring },
                        set: { _ in engine.toggleMonitoring() }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .frame(width: 210)
        .background(sidebarBG)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .home: ChatView()
        case .graph: GraphView()
        case .canvas: CanvasBoardView()
        case .timeline: TimelineView()
        case .settings:
            ScrollView { SettingsView().frame(maxWidth: 560).padding(.vertical, 20) }
                .frame(maxWidth: .infinity)
        }
    }
}
