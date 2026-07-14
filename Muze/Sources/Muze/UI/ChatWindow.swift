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
        panel.backgroundColor = NSColor(Theme.bg)
        panel.contentView = NSHostingView(rootView: QuickAskView(close: { [weak self] in self?.panel?.close() }).environmentObject(engine))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }
}

/// Compact ask bar: question in, streamed answer out, "Open Muze" for more.
struct QuickAskView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var vm = ChatViewModel()
    @FocusState private var focused: Bool
    let close: () -> Void

    // Synced to the app's design language (Theme) — no bespoke palette here.
    private let bg = Theme.bg
    private let card = Theme.surface
    private let amber = Theme.gold
    private let cream = Theme.ink

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(amber)
                TextField("Ask your memory…", text: $vm.question)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(17))
                    .foregroundStyle(cream)
                    .tint(Theme.accent)
                    .focused($focused)
                    .onSubmit { vm.ask(engine: engine) }
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
            .grain(cornerRadius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))

            if let err = vm.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let turn = vm.turns.last {
                if vm.busy, turn.answer.isEmpty {
                    GraphLoader()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                    Button("Open Muze ↗") {
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
        .grain()
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
                let map = await sm.refToDocID(containerTags: [Settings.savedTag, ConnectorImport.tag])
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
        let llm = settings.llm
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
                    You are Muze — the user's sharp, well-read thinking partner with perfect memory of what they've seen and saved. Right now it is \(df.string(from: Date())). The retrieved memories below (each tagged [n] with time + app) are your CONTEXT, not your answer.
                    How to respond:
                    - Lead with the insight, not the inventory. The user can already see their memories in the app — never narrate "you saved X, you saved Y" or "these are your memories." Instead, answer what they actually asked and add something they'd value: connect the dots across memories, surface a pattern or tension, draw the implication, or give a genuinely useful take.
                    - Write like a smart friend who remembers everything: natural, specific, confident. No preamble, no "based on your memories", no bullet-point dumps unless asked.
                    - Ground every claim in the memories and cite inline like [2]; turn timestamps into human phrasing ("this morning", "a couple weeks back"). Never invent facts not present.
                    - Only when the user explicitly says show/read/what-did-I-save should you reproduce saved text verbatim from FULL SAVED DOCUMENTS (as a quote). Otherwise, synthesize.
                    - If the memories don't actually answer it, say so in one honest sentence and suggest what might.
                    - Keep it tight: 2-5 sentences unless depth is requested.
                    """],
                ]
                // Short conversation history keeps follow-ups coherent.
                for t in turns.suffix(4).dropLast() {
                    messages.append(["role": "user", "content": t.question])
                    messages.append(["role": "assistant", "content": t.answer])
                }
                messages.append(["role": "user", "content": "Retrieved memories:\n\(context)\n\nQuestion: \(q)"])

                for try await token in llm.streamChat(messages: messages) {
                    self.turns[turnIndex].answer += token
                }
            } catch {
                self.error = error.localizedDescription
            }
            self.busy = false
        }
    }
}

/// Bundled artwork used behind the "Still recall this?" card (Michelangelo's
/// hands). Loaded once.
enum RecallArt {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "recall", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

struct ChatView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var vm = ChatViewModel()
    @FocusState private var focused: Bool
    @State private var bgImage: NSImage? = HomeBackground.image
    @State private var timeExpanded = false
    @State private var insights: [Insight] = InsightsService.cached
    @State private var insightIdx = 0
    @ObservedObject private var iconStore = IconStore.shared

    private let card = Theme.surface
    private let amber = Theme.gold
    private let cream = Theme.ink

    /// Starter prompts so a new user sees what Muze can actually do — the text
    /// shown is exactly the question it fires.
    private let suggestions = [
        "Help me find something I saw today.",
        "What should I consume next?",
        "Summarize everything I learned today.",
    ]

    private var firstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h { case 5..<12: return "Good morning"; case 12..<17: return "Good afternoon"; case 17..<22: return "Good evening"; default: return "Still up" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if vm.turns.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(greeting.uppercased()), \(firstName.uppercased())")
                        .font(Theme.ui(11, .medium))
                        .kerning(1.5)
                        .foregroundStyle(Theme.ink(0.4))
                    (
                        Text("Rediscover").foregroundColor(Theme.accent)
                            + Text(" what you've saved, or ").foregroundColor(cream)
                            + Text("ask").foregroundColor(Theme.accent)
                            + Text(" your memory anything.").foregroundColor(cream)
                    )
                    .font(Theme.display(30, .medium))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 48)
                .padding(.bottom, 8)
            }

            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Theme.ink(0.45))
                TextField("Ask your memory anything…", text: $vm.question)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(16))
                    .foregroundStyle(cream)
                    .tint(Theme.accent) // caret + selection in the app's accent, not system blue
                    .focused($focused)
                    .onSubmit { vm.ask(engine: engine) }
                if vm.busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.vertical, 15)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Theme.ink(0.28) : Theme.line))

            if vm.turns.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TRY ASKING").font(Theme.ui(9, .semibold)).kerning(1.4).foregroundStyle(Theme.ink(0.35))
                    HStack(spacing: 8) {
                        ForEach(suggestions.indices, id: \.self) { i in
                            suggestionPill(suggestions[i])
                        }
                    }
                }
                .padding(.top, 2)
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
                                    .font(Theme.ui(15, .semibold))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(Theme.gold.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                                if !turn.answer.isEmpty {
                                    Text(turn.answer).textSelection(.enabled)
                                        .font(Theme.ui(15))
                                        .foregroundStyle(Theme.ink(0.92))
                                        .lineSpacing(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if vm.busy, turn.answer.isEmpty, turn.id == vm.turns.last?.id {
                                    GraphLoader()
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
        .padding(.horizontal, 44)
        .padding(.top, 8)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topTrailing) {
            timeWidget.padding(20)
        }
        .overlay(alignment: .bottomTrailing) {
            if vm.turns.isEmpty {
                VStack(alignment: .trailing, spacing: 12) {
                    if !insights.isEmpty { noticedCard }
                    resurfaceCard
                }
                .padding(30)
            }
        }
        .background(homeBackdrop)
        .onReceive(NotificationCenter.default.publisher(for: .muzeHomeBGChanged)) { _ in
            bgImage = HomeBackground.image
        }
        .onAppear {
            focused = true
            bgImage = HomeBackground.image
            vm.loadResurface(engine: engine)
            loadInsights()
        }
    }

    /// "MUZE NOTICED" — one distilled, non-obvious observation about the user's
    /// own memories, cyclable. The Insights engine condensed into a single card.
    private func loadInsights() {
        let stale = InsightsService.generatedAt.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        if insights.isEmpty || stale {
            let settings = engine.settings
            let times = engine.appTimes
            Task {
                let r = await InsightsService.generate(settings: settings, appTimes: times)
                await MainActor.run { if !r.isEmpty { insights = r; insightIdx = 0 } }
            }
        }
    }

    private var noticedCard: some View {
        let ins = insights[insightIdx % insights.count]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: ins.icon).font(.system(size: 10)).foregroundStyle(Theme.accent)
                Text("MUZE NOTICED").font(Theme.ui(10, .semibold)).kerning(1.4).foregroundStyle(Theme.ink(0.4))
                Spacer()
                if insights.count > 1 {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { insightIdx += 1 }
                    } label: { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.ink(0.4)).help("Another")
                }
            }
            Text(ins.title).font(Theme.display(18)).foregroundStyle(Theme.ink)
                .lineLimit(2)
            Text(ins.body).font(Theme.ui(12)).foregroundStyle(Theme.ink(0.7)).lineSpacing(2).lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 300, height: 140, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .grain(cornerRadius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .transition(.opacity)
    }

    /// Optional user background image — anchored right, dimmed, with a scrim
    /// on the left so the hero text stays readable (MUZE-style).
    @ViewBuilder
    private var homeBackdrop: some View {
        if let img = bgImage {
            GeometryReader { g in
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: min(g.size.width * 0.38, 460))
                    // Fade up from the bottom so it emerges from the black,
                    // flush to the bottom edge with no gap.
                    .mask(LinearGradient(colors: [.clear, .black, .black],
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    private func fmt(_ s: Double) -> String {
        let m = Int(s) / 60
        if m < 1 { return "<1m" }
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    // Compact card top-right: total + top-3 apps/sites. Click to expand the
    // full breakdown. Fixed width so it doesn't jump around.
    private var timeWidget: some View {
        let total = engine.screenTimeSeconds
        return VStack(alignment: .trailing, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.18)) { timeExpanded.toggle() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Text("Screen time").font(Theme.ui(12, .medium)).foregroundStyle(Theme.ink(0.85))
                    Text(total > 0 ? fmt(total) : "—").font(Theme.mono(12)).foregroundStyle(Theme.ink)
                    Image(systemName: timeExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9)).foregroundStyle(Theme.ink(0.45))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.line))
            }
            .buttonStyle(.plain)

            if timeExpanded { timeBreakdown.frame(width: 300) }
        }
        .onAppear { engine.refreshStats() }
    }


    private var timeBreakdown: some View {
        let spans = Array(engine.appTimes.prefix(7))
        let maxS = spans.first?.seconds ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Where your time went today").font(Theme.ui(12, .semibold)).foregroundStyle(Theme.ink(0.85))
                Spacer()
                Image(systemName: engine.usingSystemTime ? "applelogo" : "clock")
                    .font(.system(size: 9)).foregroundStyle(Theme.ink(0.4))
            }
            if spans.isEmpty {
                Text("No activity recorded yet today.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.45))
            } else {
                ForEach(spans) { span in
                    HStack(spacing: 10) {
                        Text(span.app).font(Theme.ui(12)).foregroundStyle(Theme.ink(0.85))
                            .frame(width: 96, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 4).fill(Theme.gold.opacity(0.75))
                                .frame(width: max(5, g.size.width * (span.seconds / maxS)))
                        }
                        .frame(height: 7)
                        Text(fmt(span.seconds)).font(Theme.ui(11).monospacedDigit())
                            .foregroundStyle(Theme.ink(0.6)).frame(width: 52, alignment: .trailing)
                    }
                }
            }
            Text(engine.usingSystemTime
                 ? "From macOS Screen Time — your real activity today."
                 : "Muze's own tracking. Grant Full Disk Access for system-wide time.")
                .font(Theme.ui(10)).foregroundStyle(Theme.ink(0.4))
                .padding(.top, 2)
            if !engine.usingSystemTime {
                Button("Grant Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
                    .buttonStyle(.plain).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.gold)
            }
        }
        .tablet(padding: 14)
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    /// A clickable starter prompt: fills the question and asks immediately.
    /// The pill's text is the exact question sent.
    private func suggestionPill(_ prompt: String) -> some View {
        Button {
            vm.question = prompt
            vm.ask(engine: engine)
        } label: {
            Text(prompt).font(Theme.ui(12)).foregroundStyle(cream.opacity(0.75))
                .lineLimit(1)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Theme.accent.opacity(0.07), in: Capsule())
                .overlay(Capsule().stroke(Theme.accent.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }

    /// The "Still recall this?" card background: the bundled recall artwork,
    /// filled and clipped, under a dark scrim so the light image reads on the
    /// dark UI and text stays legible.
    private var recallCardBG: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Theme.surface)
            .overlay {
                if let img = RecallArt.image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                LinearGradient(
                    colors: [Theme.bg.opacity(0.62), Theme.bg.opacity(0.88)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
                .padding(18)
                .frame(width: 300, height: 208)
                .background(recallCardBG)
                .grain(cornerRadius: 10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                .transition(.opacity)
            } else if let r = vm.resurfaced {
                VStack(alignment: .leading, spacing: 9) {
                    Text("STILL RECALL THIS?")
                        .font(Theme.ui(9, .semibold)).kerning(1.6)
                        .foregroundStyle(Theme.ink(0.4))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Group {
                                if let icon = IconStore.shared.icon(label: r.sourceLabel, domain: r.domain, bundleID: r.bundleID) {
                                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    ZStack {
                                        Color.black
                                        Text(String(r.sourceLabel.prefix(1))).font(Theme.ui(13, .semibold)).foregroundStyle(.white)
                                    }
                                }
                            }
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            Text(r.source)
                                .font(Theme.ui(12, .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(r.text)
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.ink(0.75))
                            .lineLimit(3)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))

                    Spacer(minLength: 0)

                    HStack(spacing: 12) {
                        if let url = r.url, let u = URL(string: url) {
                            Link("Revisit →", destination: u)
                                .font(Theme.ui(11, .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        Button("Next →") { vm.loadResurface(engine: engine) }
                            .buttonStyle(.plain)
                            .font(Theme.ui(11, .medium))
                            .foregroundStyle(Theme.ink(0.55))
                    }
                }
                .padding(14)
                .frame(width: 300, height: 208, alignment: .topLeading)
                .background(recallCardBG)
                .grain(cornerRadius: 10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            }
        }
    }
}


/// Constellation loader — a procedurally generated memory graph that grows
/// while Muze searches: nodes surface one by one, link into the network, and
/// a gold retrieval pulse sweeps across whatever has appeared. Each cycle
/// lays out a brand-new constellation (seeded by the cycle index), so it
/// reads as live retrieval over real nodes, never a canned spinner.
struct GraphLoader: View {
    var label = "searching your memories…"

    private static let cycle = 5.2 // seconds per constellation
    private static let fade = 0.45 // fade-out at the end of a cycle

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let idx = UInt64(t / Self.cycle)
                    let ct = t - Double(idx) * Self.cycle
                    let graph = MiniGraph.generate(seed: idx)
                    let pts = graph.nodes.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }

                    // Whole constellation eases in, then dissolves before the next one.
                    let alpha = min(min(1, ct / 0.3), min(1, (Self.cycle - ct) / Self.fade))

                    func appear(_ i: Int) -> Double {
                        let start = 0.1 + Double(i) * 0.26
                        return max(0, min(1, (ct - start) / 0.25))
                    }
                    let visible = pts.indices.reduce(0) { appear($1) > 0 ? $0 + 1 : $0 }

                    // Retrieval pulse sweeps only the surfaced nodes.
                    let sweep = visible > 0 ? (ct * 2.2).truncatingRemainder(dividingBy: Double(visible)) : 0
                    func glow(_ i: Int) -> Double {
                        guard i < visible else { return 0 }
                        var d = abs(Double(i) - sweep)
                        d = min(d, Double(visible) - d)
                        return max(0, 1 - d / 2.0)
                    }

                    for e in graph.edges {
                        let progress = min(appear(e.a), appear(e.b))
                        guard progress > 0 else { continue }
                        var p = Path()
                        p.move(to: pts[e.a])
                        p.addLine(to: pts[e.b])
                        let drawn = p.trimmedPath(from: 0, to: progress) // links draw in
                        ctx.stroke(drawn, with: .color(Theme.ink(0.15 * alpha)), lineWidth: 1)
                        let hot = max(glow(e.a), glow(e.b))
                        if hot > 0.05 {
                            ctx.stroke(drawn, with: .color(Theme.gold.opacity(0.55 * hot * alpha)), lineWidth: 1)
                        }
                    }
                    for (i, pt) in pts.enumerated() {
                        let a = appear(i)
                        guard a > 0 else { continue }
                        let hot = glow(i)
                        let r = (1.4 + 1.4 * a + 2.2 * hot) * (0.6 + 0.4 * a)
                        if hot > 0.55 { // soft halo on the node being "read"
                            let hr = r + 4
                            ctx.fill(
                                Path(ellipseIn: CGRect(x: pt.x - hr, y: pt.y - hr, width: hr * 2, height: hr * 2)),
                                with: .color(Theme.gold.opacity(0.2 * hot * alpha))
                            )
                        }
                        let color = hot > 0.35
                            ? Theme.gold.opacity((0.35 + 0.65 * hot) * alpha)
                            : Theme.ink(0.32 * a * alpha)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                            with: .color(color)
                        )
                    }
                }
            }
            .frame(width: 170, height: 52)

            Text(label)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.ink(0.45))
        }
        .padding(.vertical, 2)
        .transition(.opacity)
    }
}

/// A small random constellation: spaced-out nodes joined into a spanning tree
/// plus a couple of cross-links. Deterministic per seed, so every loader
/// cycle grows a different graph without any view state.
private struct MiniGraph {
    struct Edge { let a: Int; let b: Int }
    var nodes: [CGPoint]
    var edges: [Edge]

    // The canvas is ~3× wider than tall — weigh y less when measuring spacing.
    private static func dist(_ p: CGPoint, _ q: CGPoint) -> CGFloat {
        hypot(p.x - q.x, (p.y - q.y) * 0.35)
    }

    static func generate(seed: UInt64) -> MiniGraph {
        var rng = SplitMix64(state: seed &+ 0x5DEECE66D)
        let count = Int.random(in: 9...12, using: &rng)

        var pts: [CGPoint] = []
        var attempts = 0
        while pts.count < count, attempts < 400 {
            attempts += 1
            let p = CGPoint(
                x: CGFloat.random(in: 0.04...0.96, using: &rng),
                y: CGFloat.random(in: 0.14...0.86, using: &rng)
            )
            if pts.allSatisfy({ dist($0, p) > 0.09 }) { pts.append(p) }
        }

        // Spanning tree: each new node links to its nearest earlier node.
        var edges: [Edge] = []
        for i in 1..<pts.count {
            var best = 0
            var bestD = CGFloat.infinity
            for j in 0..<i where dist(pts[j], pts[i]) < bestD {
                bestD = dist(pts[j], pts[i])
                best = j
            }
            edges.append(Edge(a: best, b: i))
        }
        // A couple of short cross-links so it reads as a graph, not a chain.
        for _ in 0..<2 where pts.count > 4 {
            let a = Int.random(in: 0..<pts.count, using: &rng)
            let b = Int.random(in: 0..<pts.count, using: &rng)
            guard a != b, dist(pts[a], pts[b]) < 0.3,
                  !edges.contains(where: { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) })
            else { continue }
            edges.append(Edge(a: a, b: b))
        }
        return MiniGraph(nodes: pts, edges: edges)
    }
}

/// Tiny deterministic RNG (SplitMix64) so each loader cycle derives its
/// constellation purely from the cycle index — no stored state to manage.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D4A9C596A25F31
        return z ^ (z >> 31)
    }
}
