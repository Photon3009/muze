import AppKit
import SwiftUI

/// Minimal quick-ask widget summoned with the global hotkey — Spotlight-like,
/// from anywhere. The full experience lives in the main app window.
@MainActor
final class ChatPanelController {
    static let shared = ChatPanelController()
    private var panel: NSPanel?

    func toggle(engine: Engine) {
        if let p = panel, p.isVisible {
            p.close()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.10, alpha: 1)
        panel.contentView = NSHostingView(rootView: QuickAskView(close: { [weak self] in self?.panel?.close() }).environmentObject(engine))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }
}

/// Compact ask bar: question in, streamed answer out, "Open Recall" for more.
struct QuickAskView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var vm = ChatViewModel()
    @FocusState private var focused: Bool
    let close: () -> Void

    private let bg = Color(red: 0.12, green: 0.11, blue: 0.10)
    private let card = Color(red: 0.165, green: 0.15, blue: 0.14)
    private let amber = Color(red: 0.85, green: 0.66, blue: 0.28)
    private let cream = Color(red: 0.93, green: 0.90, blue: 0.85)

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(amber)
                TextField("Ask your memory…", text: $vm.question)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(cream)
                    .focused($focused)
                    .onSubmit { vm.ask(engine: engine) }
                if vm.busy { ProgressView().controlSize(.small) }
                Menu {
                    Picker("Scope", selection: $vm.scope) {
                        Text("Saved").tag(GraphService.Scope.saved)
                        Text("Screen").tag(GraphService.Scope.screen)
                        Text("All").tag(GraphService.Scope.all)
                    }
                } label: {
                    Text(vm.scope.rawValue).font(.caption2).foregroundStyle(cream.opacity(0.5))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 58)
            }
            .padding(13)
            .background(card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(amber.opacity(0.5), lineWidth: 1))

            if let turn = vm.turns.last {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !turn.answer.isEmpty {
                            Text(turn.answer)
                                .foregroundStyle(cream.opacity(0.92))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                HStack {
                    if !turn.citations.isEmpty {
                        Text("\(turn.citations.count) memories used").font(.caption2).foregroundStyle(cream.opacity(0.4))
                    }
                    Spacer()
                    Button("Open Recall ↗") {
                        close()
                        MainWindowController.shared.show(engine: engine)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.bold())
                    .foregroundStyle(amber)
                }
            } else {
                Spacer()
                Text("Enter to ask · Esc to dismiss")
                    .font(.caption2).foregroundStyle(cream.opacity(0.3))
            }
        }
        .padding(14)
        .frame(width: 620, height: 380)
        .background(bg)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
        .onExitCommand { close() }
    }
}

struct Citation: Identifiable {
    let id: String
    let index: Int
    let text: String
    let app: String?
    let when: String?
    let url: String?
}

struct ChatTurn: Identifiable {
    let id = UUID()
    let question: String
    var answer: String = ""
    var citations: [Citation] = []
}

struct Resurfaced {
    let source: String // "a tweet from X" style label
    let sourceLabel: String
    let domain: String?
    let bundleID: String?
    let when: String // relative ("last month")
    let text: String
    let url: String?
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var question = ""
    @Published var turns: [ChatTurn] = []
    @Published var busy = false
    @Published var error: String?
    @Published var scope: GraphService.Scope = .all
    @Published var resurfaced: Resurfaced?
    @Published var resurfaceExhausted = false
    private var resurfaceIDs: [String] = []
    private var resurfaceIndex = 0

    /// "Do you still recall this?" — resurface a random saved memory.
    func loadResurface(engine: Engine) {
        let sm = SupermemoryClient(baseURL: engine.settings.supermemoryURLValue, apiKey: engine.settings.supermemoryKey)
        Task {
            if resurfaceIDs.isEmpty {
                let map = await sm.refToDocID(containerTags: [Settings.savedTag])
                resurfaceIDs = Array(map.values).shuffled()
            }
            guard !resurfaceIDs.isEmpty else { return }
            // No looping: once every saved memory has resurfaced, say so and close.
            if resurfaceIndex >= resurfaceIDs.count {
                self.resurfaced = nil
                self.resurfaceExhausted = true
                self.resurfaceIDs = []
                self.resurfaceIndex = 0
                Task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    self.resurfaceExhausted = false
                }
                return
            }
            let id = resurfaceIDs[resurfaceIndex]
            resurfaceIndex += 1
            guard let (content, meta) = await sm.documentInfo(id: id) else { return }
            let body = content.components(separatedBy: "\n\n(Saved from").first ?? content

            var domain: String?
            var label = meta["app_name"] ?? "somewhere"
            if let url = meta["url"], let host = URL(string: url)?.host?.lowercased() {
                domain = host.replacingOccurrences(of: "www.", with: "")
                if domain!.contains("x.com") || domain!.contains("twitter") { label = "X" }
                else if let d = domain { label = d.components(separatedBy: ".").dropLast().last?.capitalized ?? d }
            }
            let kind = meta["kind"] == "region-ocr" ? "a snippet" : (domain != nil ? "this" : "a note")

            var when = ""
            if let iso = meta["captured_at"], let date = ISO8601DateFormatter().date(from: iso) {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .full
                when = f.localizedString(for: date, relativeTo: Date())
            }
            self.resurfaced = Resurfaced(
                source: "You saved \(kind) from \(label) \(when)",
                sourceLabel: label,
                domain: domain,
                bundleID: meta["app"],
                when: when,
                text: String(body.prefix(400)),
                url: meta["url"]
            )
        }
    }

    func ask(engine: Engine) {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        busy = true
        error = nil
        question = ""
        turns.append(ChatTurn(question: q))
        let turnIndex = turns.count - 1

        let settings = engine.settings
        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        let ollama = OllamaClient(baseURL: settings.ollamaURLValue, model: settings.ollamaModel)
        let tag = settings.containerTag

        _ = tag
        let tags = scope.tags
        Task {
            do {
                var hits = await sm.searchAll(q, containerTags: tags, limit: 14, threshold: 0.2)
                if let scope = TimeScope.parse(q) {
                    let scoped = hits.filter { scope.contains(iso: $0.metadata?["captured_at"]?.stringValue) }
                    if !scoped.isEmpty { hits = scoped }
                }
                // Near-duplicate memories (scroll captures) waste context — drop them.
                var unique: [SupermemoryClient.SearchHit] = []
                for h in hits {
                    let text = h.memory ?? ""
                    if !unique.contains(where: { TextSimilarity.jaccard($0.memory ?? "", text) > 0.8 }) {
                        unique.append(h)
                    }
                }
                let top = Array(unique.prefix(8))
                let citations = top.enumerated().map { i, h in
                    Citation(
                        id: h.id,
                        index: i + 1,
                        text: h.memory ?? "",
                        app: h.metadata?["app_name"]?.stringValue,
                        when: h.metadata?["captured_at"]?.stringValue,
                        url: h.metadata?["url"]?.stringValue
                    )
                }
                self.turns[turnIndex].citations = citations
                guard !top.isEmpty else {
                    self.turns[turnIndex].answer = "I haven't seen anything related to that on your screen yet."
                    self.busy = false
                    return
                }

                let df = DateFormatter()
                df.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm"
                var context = citations
                    .map { c in
                        let when = (c.when ?? "").prefix(16).replacingOccurrences(of: "T", with: " ")
                        return "[\(c.index)] \(when) · \(c.app ?? "") — \(c.text)"
                    }
                    .joined(separator: "\n")

                // Resolve the top hits to their parent documents and include
                // the FULL saved content — facts alone can't answer "show me
                // what I saved".
                let refMap = await sm.refToDocID(containerTags: tags)
                var seenRefs = Set<String>()
                var fullDocs: [String] = []
                for h in top {
                    guard fullDocs.count < 3,
                          let ref = h.metadata?["ref"]?.stringValue,
                          !seenRefs.contains(ref),
                          let docID = refMap[ref] else { continue }
                    seenRefs.insert(ref)
                    if let content = await sm.documentContent(id: docID) {
                        let title = h.metadata?["page_title"]?.stringValue
                            ?? h.metadata?["window_title"]?.stringValue
                            ?? h.metadata?["app_name"]?.stringValue ?? "saved item"
                        let when = (h.metadata?["captured_at"]?.stringValue ?? "").prefix(10)
                        fullDocs.append("=== Saved item: \(title) (\(when)) ===\n\(String(content.prefix(2500)))")
                    }
                }
                if !fullDocs.isEmpty {
                    let docsBlock: String = fullDocs.joined(separator: "\n\n")
                    context = "FULL SAVED DOCUMENTS:\n\n\(docsBlock)\n\nRelated memory facts:\n\(context)"
                }

                var messages: [[String: String]] = [
                    ["role": "system", "content": """
                    You are Recall, the user's personal screen memory on their Mac. Right now it is \(df.string(from: Date())).
                    You are given memories retrieved from what the user actually saw on screen, each tagged [n] with its timestamp and app.
                    Rules:
                    - Answer the question directly in the first sentence, conversational and natural — you're a sharp assistant, not a search index.
                    - For questions ABOUT the past, synthesize across memories; cite facts inline like [2] and convert timestamps to friendly phrasing ("this morning", "around 4pm yesterday").
                    - When the user asks WHAT THEY SAVED about a topic, or to see/show/read a memory: name each saved item ("You saved Naval's Substack article 'Sell the Truth' on July 10") and then reproduce its saved text from FULL SAVED DOCUMENTS — complete and verbatim, as a quote. Do NOT summarize it away.
                    - Ignore memories that don't help. If none answer the question, say so in one sentence — no apologies, no filler.
                    - Brevity for questions (1-4 sentences); full fidelity for "show me what I saved".
                    """],
                ]
                // Short conversation history keeps follow-ups coherent.
                for t in turns.suffix(4).dropLast() {
                    messages.append(["role": "user", "content": t.question])
                    messages.append(["role": "assistant", "content": t.answer])
                }
                messages.append(["role": "user", "content": "Retrieved memories:\n\(context)\n\nQuestion: \(q)"])

                for try await token in ollama.streamChat(messages: messages) {
                    self.turns[turnIndex].answer += token
                }
            } catch {
                self.error = error.localizedDescription
            }
            self.busy = false
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var vm = ChatViewModel()
    @FocusState private var focused: Bool

    private let bg = Color(red: 0.12, green: 0.11, blue: 0.10)
    private let card = Color(red: 0.165, green: 0.15, blue: 0.14)
    private let amber = Color(red: 0.85, green: 0.66, blue: 0.28)
    private let cream = Color(red: 0.93, green: 0.90, blue: 0.85)

    private var firstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if vm.turns.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome, \(firstName)")
                        .font(.caption)
                        .foregroundStyle(cream.opacity(0.55))
                    (
                        Text("Rediscover").italic().foregroundColor(amber)
                            + Text(" your saved memories ").foregroundColor(cream)
                            + Text("or ask").italic().foregroundColor(amber)
                    )
                    .font(.system(size: 25, weight: .semibold, design: .serif))
                }
                .padding(.top, 6)
            }

            HStack(spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(amber)
                TextField("What can I help you recall?", text: $vm.question)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(cream)
                    .focused($focused)
                    .onSubmit { vm.ask(engine: engine) }
                if vm.busy { ProgressView().controlSize(.small) }
            }
            .padding(14)
            .background(card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(amber.opacity(0.55), lineWidth: 1))
            .shadow(color: amber.opacity(0.18), radius: 14)

            HStack(spacing: 8) {
                chip("bookmark.fill", "Save \(engine.saveHotkeyLabel)") { SavePanelController.shared.trigger(engine: engine) }
                chip("circle.hexagongrid.fill", "Graph") {
                    NotificationCenter.default.post(name: .recallSwitchTab, object: MainTab.graph)
                }
                chip("clock", "Timeline") {
                    NotificationCenter.default.post(name: .recallSwitchTab, object: MainTab.timeline)
                }
                Spacer()
                Picker("", selection: $vm.scope) {
                    Text("Saved").tag(GraphService.Scope.saved)
                    Text("Screen").tag(GraphService.Scope.screen)
                    Text("All").tag(GraphService.Scope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }

            if let err = vm.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(vm.turns) { turn in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(turn.question)
                                    .font(.callout.bold())
                                    .padding(8)
                                    .background(.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                                if !turn.answer.isEmpty {
                                    Text(turn.answer).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if !turn.citations.isEmpty {
                                    DisclosureGroup("\(turn.citations.count) memories used") {
                                        ForEach(turn.citations) { c in
                                            HStack(alignment: .top, spacing: 8) {
                                                Text("[\(c.index)]").font(.caption.monospaced()).foregroundStyle(.purple)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(c.text).font(.caption)
                                                    HStack(spacing: 6) {
                                                        if let app = c.app { Text(app) }
                                                        if let when = c.when {
                                                            Text(when.prefix(16).replacingOccurrences(of: "T", with: " "))
                                                        }
                                                    }
                                                    .font(.caption2).foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                if let url = c.url, let u = URL(string: url) {
                                                    Button { NSWorkspace.shared.open(u) } label: {
                                                        Image(systemName: "arrow.up.right.square")
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                            .id(turn.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: vm.turns.last?.answer) {
                    if let last = vm.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(26)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) {
            if vm.turns.isEmpty {
                resurfaceCard.padding(26)
            }
        }
        .background(bg)
        .preferredColorScheme(.dark)
        .onAppear {
            focused = true
            vm.loadResurface(engine: engine)
        }
    }

    private func chip(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(card, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12)))
            .foregroundStyle(cream.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    /// The reference card: warm angular-gradient frame, source icon,
    /// "You saved … last month", body text, centered "Check next".
    private var resurfaceCard: some View {
        Group {
            if vm.resurfaceExhausted {
                VStack(spacing: 8) {
                    Text("✦").font(.title2).foregroundStyle(cream)
                    Text("You've revisited everything you saved.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(cream.opacity(0.9))
                    Text("New memories will resurface here.")
                        .font(.caption).foregroundStyle(cream.opacity(0.5))
                }
                .padding(22)
                .frame(width: 330)
                .background(
                    AngularGradient(
                        colors: [
                            Color(red: 0.255, green: 0.212, blue: 0.145),
                            Color(red: 0.439, green: 0.337, blue: 0.157),
                            Color(red: 0.145, green: 0.141, blue: 0.141),
                            Color(red: 0.255, green: 0.212, blue: 0.145),
                        ],
                        center: .bottomLeading
                    ),
                    in: RoundedRectangle(cornerRadius: 22)
                )
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
                .transition(.opacity)
            } else if let r = vm.resurfaced {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Like Adam's spark, do you still recall\nthis touch you saved in memory?")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(cream.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Group {
                                if let icon = IconStore.shared.icon(label: r.sourceLabel, domain: r.domain, bundleID: r.bundleID) {
                                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    ZStack {
                                        Color.black
                                        Text(String(r.sourceLabel.prefix(1))).font(.headline).foregroundStyle(.white)
                                    }
                                }
                            }
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                            Text(r.source)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(r.text)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = r.url, let u = URL(string: url) {
                            Link("Click here to revisit..", destination: u)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))

                    HStack {
                        Spacer()
                        Button("Check next") { vm.loadResurface(engine: engine) }
                            .buttonStyle(.plain)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(cream)
                        Spacer()
                    }
                    .padding(.bottom, 2)
                }
                .padding(18)
                .frame(width: 330)
                .background(
                    AngularGradient(
                        colors: [
                            Color(red: 0.255, green: 0.212, blue: 0.145),
                            Color(red: 0.439, green: 0.337, blue: 0.157),
                            Color(red: 0.392, green: 0.306, blue: 0.154),
                            Color(red: 0.145, green: 0.141, blue: 0.141),
                            Color(red: 0.255, green: 0.212, blue: 0.145),
                        ],
                        center: .bottomLeading
                    ),
                    in: RoundedRectangle(cornerRadius: 22)
                )
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
            }
        }
    }
}
