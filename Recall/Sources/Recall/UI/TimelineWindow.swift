import AppKit
import SwiftUI

/// Day-scrubbable timeline of kept frames, grouped visually by hour.
@MainActor
final class TimelineWindowController {
    static let shared = TimelineWindowController()
    private var window: NSWindow?

    func show(engine: Engine) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "Recall Timeline"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: TimelineView().environmentObject(engine))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

struct TimelineView: View {
    @EnvironmentObject var engine: Engine
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var days: [Date] = []
    @State private var frames: [FrameRecord] = []
    @State private var selected: FrameRecord?

    private var hourGroups: [(hour: Int, frames: [FrameRecord])] {
        Dictionary(grouping: frames) { Calendar.current.component(.hour, from: $0.capturedAt) }
            .sorted { $0.key < $1.key }
            .map { (hour: $0.key, frames: $0.value) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                dayPicker
                Divider()
                if frames.isEmpty {
                    Spacer()
                    Text("No memories this day").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                            ForEach(hourGroups, id: \.hour) { group in
                                Section {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
                                        ForEach(group.frames, id: \.id) { frame in
                                            frameCard(frame)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                } header: {
                                    Text(String(format: "%02d:00", group.hour))
                                        .font(.caption.monospacedDigit().bold())
                                        .padding(.vertical, 4).padding(.horizontal, 14)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.regularMaterial)
                                }
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
            .frame(minWidth: 560)

            if let sel = selected {
                detail(sel).frame(minWidth: 300, maxWidth: 380)
            }
        }
        .onAppear { reload() }
        .onChange(of: day) { reload() }
    }

    private var dayPicker: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            DatePicker("", selection: $day, displayedComponents: .date).labelsHidden()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDateInToday(day))
            Spacer()
            Text("\(frames.count) memories").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func frameCard(_ frame: FrameRecord) -> some View {
        Button {
            selected = frame
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if let thumb = frame.thumbPath,
                   let img = NSImage(contentsOf: Thumbnailer.thumbsDir.appendingPathComponent(thumb)) {
                    Image(nsImage: img)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 100).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 100)
                        .overlay(Image(systemName: "text.alignleft").foregroundStyle(.secondary))
                }
                Text(frame.appName).font(.caption.bold()).lineLimit(1)
                Text(frame.capturedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected?.id == frame.id ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func detail(_ frame: FrameRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let thumb = frame.thumbPath,
                   let img = NSImage(contentsOf: Thumbnailer.thumbsDir.appendingPathComponent(thumb)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text("\(frame.appName)\(frame.windowTitle.isEmpty ? "" : " — \(frame.windowTitle)")")
                    .font(.headline)
                Text(frame.capturedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
                if let url = frame.url, let u = URL(string: url) {
                    Link(url, destination: u).font(.caption).lineLimit(2)
                }
                Button("Ask about this…") {
                    ChatPanelController.shared.toggle(engine: engine)
                }
                Divider()
                Text(frame.ocrText.isEmpty ? "(no readable text)" : frame.ocrText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
    }

    private func shift(_ delta: Int) {
        day = Calendar.current.date(byAdding: .day, value: delta, to: day) ?? day
    }

    private func reload() {
        Task {
            let d = day
            let f = await Store.shared.frames(onDay: d)
            let ds = await Store.shared.daysWithFrames()
            await MainActor.run {
                frames = f
                days = ds
            }
        }
    }
}
