import AppKit
import SwiftUI

/// Obsidian-style memory graph: topic hubs (from tags) → source nodes
/// (sites/apps, with icons) → leaf dots (individual memories), thin white
/// edges on charcoal with a dotted grid, and a floating preview card.
@MainActor
final class GraphWindowController {
    static let shared = GraphWindowController()
    private var window: NSWindow?

    func show(engine: Engine) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = "Memory Graph"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.105, blue: 0.10, alpha: 1)
        w.contentView = NSHostingView(rootView: GraphView().environmentObject(engine))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

// MARK: - graph model

struct SourceMeta: Hashable {
    let label: String
    let domain: String? // favicon source (web)
    let bundleID: String? // real app icon (local apps)
}

enum VizKind: Hashable {
    case hub(String) // tag label
    case source(SourceMeta) // site/app with real icon
    case memory(GraphNode)

    var radius: Double {
        switch self {
        case .hub: return 30
        case .source: return 24
        case .memory: return 9
        }
    }
}

struct VizNode: Identifiable {
    let id: String
    let kind: VizKind
}

struct VizEdge: Hashable {
    let a: String
    let b: String
    let restLength: Double
    let faint: Bool
}

/// Which "source" bucket a memory belongs to, and how to fetch its real icon.
enum SourceInfo {
    private static let brands: [(match: String, label: String, domain: String)] = [
        ("youtube", "YouTube", "youtube.com"), ("youtu.be", "YouTube", "youtube.com"),
        ("twitter", "X", "x.com"),
        ("reddit", "Reddit", "reddit.com"),
        ("whatsapp", "WhatsApp", "whatsapp.com"),
        ("spotify", "Spotify", "spotify.com"),
        ("substack", "Substack", "substack.com"),
        ("github", "GitHub", "github.com"),
        ("instagram", "Instagram", "instagram.com"),
        ("linkedin", "LinkedIn", "linkedin.com"),
        ("chatgpt", "ChatGPT", "chatgpt.com"),
        ("claude.ai", "Claude", "claude.ai"),
    ]

    private static let browserHints = ["chrome", "brave", "safari", "arc", "edge", "firefox", "browser"]
    static func isBrowser(bundleID: String, name: String) -> Bool {
        let s = (bundleID + " " + name).lowercased()
        return browserHints.contains { s.contains($0) }
    }

    static func meta(for node: GraphNode) -> SourceMeta {
        if let url = node.url, let host = URL(string: url)?.host?.lowercased() {
            let h = host.replacingOccurrences(of: "www.", with: "")
            if h == "x.com" { return SourceMeta(label: "X", domain: "x.com", bundleID: nil) }
            for b in brands where h.contains(b.match) {
                return SourceMeta(label: b.label, domain: b.domain, bundleID: nil)
            }
            // Unknown site: its own node, its own favicon.
            return SourceMeta(label: h, domain: h, bundleID: nil)
        }
        // A browser with no captured URL: show a neutral web node, never the
        // browser's own app icon.
        if isBrowser(bundleID: node.bundleID, name: node.app) {
            return SourceMeta(label: "Web", domain: nil, bundleID: nil)
        }
        return SourceMeta(label: node.app, domain: nil, bundleID: node.bundleID.isEmpty ? nil : node.bundleID)
    }
}

// MARK: - simulation

@MainActor
final class GraphSim: ObservableObject {
    struct Body {
        var node: VizNode
        var x: Double
        var y: Double
        var vx: Double = 0
        var vy: Double = 0
    }

    @Published var bodies: [Body] = []
    @Published var edges: [VizEdge] = []
    @Published var loading = true
    @Published var selected: VizNode?
    @Published var hovered: VizNode?
    @Published var scope: GraphService.Scope = .saved
    @Published var fullContent: [String: String] = [:] // docID → content

    private var idToIndex: [String: Int] = [:]
    private var springs: [(i: Int, j: Int, rest: Double)] = []
    private var ticker: Timer?
    private var alpha = 1.0
    private var pinned = Set<String>() // nodes the user placed by hand

    func load(engine: Engine) {
        loading = true
        selected = nil
        hovered = nil
        let snapshot = GraphService.SettingsSnapshot(
            supermemoryURL: engine.settings.supermemoryURLValue,
            supermemoryKey: engine.settings.supermemoryKey
        )
        let scope = self.scope
        Task {
            let (memories, semantic) = await GraphService.shared.build(snapshot, scope: scope)
            await MainActor.run { self.assemble(memories: memories, semantic: semantic) }
        }
    }

    /// memories → leaf nodes; their sources → icon nodes; frequent tags → hubs.
    private func assemble(memories: [GraphNode], semantic: [GraphEdge]) {
        var nodes: [VizNode] = []
        var edgeSet: Set<VizEdge> = []

        // Sources
        var sourceOf: [String: String] = [:] // memoryID → source label
        var sourceMeta: [String: SourceMeta] = [:]
        for m in memories {
            let meta = SourceInfo.meta(for: m)
            sourceOf[m.id] = meta.label
            sourceMeta[meta.label] = meta
        }
        let sourceKeys = Set(sourceMeta.keys)

        // Hubs: tags carried by ≥2 memories (top 8 by count)
        var tagCounts: [String: Int] = [:]
        for m in memories {
            for t in Set(m.tags.map { $0.lowercased() }) { tagCounts[t, default: 0] += 1 }
        }
        let hubTags = tagCounts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(8).map(\.key)

        for tag in hubTags { nodes.append(VizNode(id: "hub:\(tag)", kind: .hub(tag))) }
        for key in sourceKeys.sorted() {
            if let meta = sourceMeta[key] { nodes.append(VizNode(id: "src:\(key)", kind: .source(meta))) }
        }
        for m in memories { nodes.append(VizNode(id: m.id, kind: .memory(m))) }

        for m in memories {
            let src = "src:\(sourceOf[m.id] ?? "Web")"
            edgeSet.insert(VizEdge(a: src, b: m.id, restLength: 75, faint: false))
            for t in Set(m.tags.map { $0.lowercased() }) where hubTags.contains(t) {
                edgeSet.insert(VizEdge(a: "hub:\(t)", b: src, restLength: 160, faint: false))
            }
        }
        // Semantic memory↔memory links, faint.
        for e in semantic {
            edgeSet.insert(VizEdge(a: min(e.a, e.b), b: max(e.a, e.b), restLength: 130, faint: true))
        }

        // Deterministic seed layout.
        bodies = nodes.enumerated().map { i, n in
            let angle = Double(i) / Double(max(nodes.count, 1)) * 2 * .pi
            let r: Double
            switch n.kind {
            case .hub: r = 40
            case .source: r = 160
            case .memory: r = 280
            }
            return Body(node: n, x: cos(angle) * r + Double(i % 3) * 8, y: sin(angle) * r)
        }
        idToIndex = Dictionary(uniqueKeysWithValues: bodies.enumerated().map { ($0.element.node.id, $0.offset) })
        springs = edgeSet.compactMap { e in
            guard let i = idToIndex[e.a], let j = idToIndex[e.b] else { return nil }
            return (i, j, e.restLength)
        }
        edges = Array(edgeSet)
        pinned.removeAll()
        alpha = 1.0
        loading = false
        restartTicker()
    }

    private func restartTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Move a node under the cursor and pin it there; re-energize the layout so
    /// its connected nodes rearrange around it.
    func dragNode(id: String, to world: CGPoint) {
        guard let i = idToIndex[id] else { return }
        bodies[i].x = world.x
        bodies[i].y = world.y
        bodies[i].vx = 0
        bodies[i].vy = 0
        pinned.insert(id)
        alpha = max(alpha, 0.35)
        if ticker == nil { restartTicker() }
    }

    private func tick() {
        guard alpha > 0.02, !bodies.isEmpty else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        let pinnedIdx = Set(pinned.compactMap { idToIndex[$0] })
        alpha *= 0.985
        var next = bodies

        for i in next.indices {
            var fx = -next[i].x * 0.012
            var fy = -next[i].y * 0.012
            let ri = next[i].node.kind.radius

            for j in next.indices where j != i {
                let dx = next[i].x - next[j].x
                let dy = next[i].y - next[j].y
                let d2 = max(dx * dx + dy * dy, 25)
                let strength = 900.0 + (ri + next[j].node.kind.radius) * 40
                let f = strength / d2
                fx += dx / sqrt(d2) * f
                fy += dy / sqrt(d2) * f
            }
            next[i].vx = (next[i].vx + fx) * 0.6
            next[i].vy = (next[i].vy + fy) * 0.6
        }

        for s in springs {
            let dx = next[s.j].x - next[s.i].x
            let dy = next[s.j].y - next[s.i].y
            let d = max(sqrt(dx * dx + dy * dy), 1)
            let f = (d - s.rest) * 0.03
            next[s.i].vx += dx / d * f
            next[s.i].vy += dy / d * f
            next[s.j].vx -= dx / d * f
            next[s.j].vy -= dy / d * f
        }

        for i in next.indices {
            if pinnedIdx.contains(i) { next[i].vx = 0; next[i].vy = 0; continue } // held by the user
            next[i].x += next[i].vx * alpha * 4
            next[i].y += next[i].vy * alpha * 4
        }
        bodies = next
    }

    func node(at point: CGPoint, transform: GraphTransform, in size: CGSize) -> VizNode? {
        let gx: Double = (point.x - size.width / 2 - transform.pan.width) / transform.scale
        let gy: Double = (point.y - size.height / 2 - transform.pan.height) / transform.scale
        var best: (node: VizNode, d: Double)?
        for b in bodies {
            let d = hypot(b.x - gx, b.y - gy)
            let hit = b.node.kind.radius + 8 / transform.scale
            if d < hit, d < (best?.d ?? .infinity) {
                best = (b.node, d)
            }
        }
        return best?.node
    }

    func screenPosition(of id: String, transform: GraphTransform, in size: CGSize) -> CGPoint? {
        guard let i = idToIndex[id], bodies.indices.contains(i) else { return nil }
        let b = bodies[i]
        return CGPoint(
            x: size.width / 2 + transform.pan.width + b.x * transform.scale,
            y: size.height / 2 + transform.pan.height + b.y * transform.scale
        )
    }

    /// Preview card wants real text — fetch the full document lazily.
    func ensureContent(for node: GraphNode, engine: Engine) {
        guard fullContent[node.id] == nil else { return }
        let base = engine.settings.supermemoryURLValue
        Task {
            var req = URLRequest(url: base.appendingPathComponent("v3/documents/\(node.id)"))
            req.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = obj["content"] as? String else { return }
            await MainActor.run { self.fullContent[node.id] = content }
        }
    }
}

struct GraphTransform {
    var scale: CGFloat = 1
    var pan: CGSize = .zero
}

// MARK: - view

struct GraphView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var sim = GraphSim()
    @ObservedObject private var icons = IconStore.shared
    @State private var transform = GraphTransform()
    @State private var dragStart: CGSize?
    @State private var magnifyBase: CGFloat?
    @State private var draggingNodeID: String?
    @State private var nameDraft = ""

    private var selectedMemory: GraphNode? {
        if let s = sim.selected, case .memory(let n) = s.kind { return n }
        return nil
    }

    private let bg = Theme.bg
    private let leaf = Theme.accent // memory dots (orange)
    private let nodeFill = Theme.surface

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                canvas(size: geo.size)
                    .gesture(boardDrag(size: geo.size))
                    .gesture(magnifyGesture)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            sim.hovered = sim.node(at: p, transform: transform, in: geo.size)
                            if case .memory(let m) = sim.hovered?.kind { sim.ensureContent(for: m, engine: engine) }
                        case .ended:
                            sim.hovered = nil
                        }
                    }

                // Floating preview near a HOVERED node (read-only).
                if let viz = sim.hovered, sim.selected == nil,
                   case .memory(let node) = viz.kind,
                   let pos = sim.screenPosition(of: viz.id, transform: transform, in: geo.size) {
                    previewCard(node)
                        .frame(width: 300)
                        .position(
                            x: min(max(pos.x - 210, 170), geo.size.width - 170),
                            y: min(max(pos.y, 130), geo.size.height - 150)
                        )
                        .allowsHitTesting(false)
                }
            }

            // Editable detail for a SELECTED node — pinned top-right.
            if let node = selectedMemory {
                nameEditor(node)
                    .frame(width: 320)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 18)
                    .padding(.top, 58) // clear the top bar
            }

            if sim.loading {
                ProgressView("Charting your memories…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sim.bodies.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing saved yet").font(.title3.bold())
                    Text("Select anything, press ⌥S, and your first star appears here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            toolbar
        }
        .background(bg)
        .preferredColorScheme(.dark)
        .onAppear { sim.load(engine: engine) }
        .onChange(of: sim.selected?.id) {
            if let n = selectedMemory {
                nameDraft = n.title == "Untitled" ? "" : n.title
            }
        }
    }

    private func nameEditor(_ node: GraphNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Name this memory").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.gold)
                Spacer()
                Button { sim.selected = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink(0.5))
            }
            TextField("Give it a name…", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(Theme.ui(15))
                .foregroundStyle(Theme.ink)
                .padding(10)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { saveName(node) }
            if !node.summary.isEmpty {
                Text(node.summary).font(Theme.ui(12)).foregroundStyle(Theme.ink(0.55)).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Save name") { saveName(node) }
                    .buttonStyle(PillButton(bg: Theme.gold, fg: .black))
            }
        }
        .tablet()
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private func saveName(_ node: GraphNode) {
        GraphNames.set(node.id, nameDraft)
        sim.selected = nil
        sim.load(engine: engine)
    }

    // MARK: canvas

    private func canvas(size: CGSize) -> some View {
        Canvas { ctx, sz in
            // dotted grid
            let step: CGFloat = 90
            let dot = Color.white.opacity(0.06)
            var y: CGFloat = step / 2
            while y < sz.height {
                var x: CGFloat = step / 2
                while x < sz.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(dot))
                    x += step
                }
                y += step
            }

            let cx = sz.width / 2 + transform.pan.width
            let cy = sz.height / 2 + transform.pan.height
            let s = transform.scale
            func screen(_ b: GraphSim.Body) -> CGPoint { CGPoint(x: cx + b.x * s, y: cy + b.y * s) }
            let byID = Dictionary(uniqueKeysWithValues: sim.bodies.map { ($0.node.id, $0) })

            for e in sim.edges {
                guard let a = byID[e.a], let b = byID[e.b] else { continue }
                var path = Path()
                path.move(to: screen(a))
                path.addLine(to: screen(b))
                ctx.stroke(path, with: .color(.white.opacity(e.faint ? 0.10 : 0.55)), lineWidth: e.faint ? 0.6 : 1.0)
            }

            for b in sim.bodies {
                let p = screen(b)
                let isActive = sim.selected?.id == b.node.id || sim.hovered?.id == b.node.id
                switch b.node.kind {
                case .memory:
                    let r: CGFloat = (isActive ? 11 : 9) * min(s, 1.6)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(isActive ? leaf : leaf.opacity(0.9)))
                case .source(let meta):
                    let r: CGFloat = 24 * min(s, 1.6)
                    drawCircleNode(ctx, at: p, radius: r, active: isActive)
                    if let nsImage = icons.icon(label: meta.label, domain: meta.domain, bundleID: meta.bundleID) {
                        // Full-bleed: the icon covers the whole circle.
                        let inset: CGFloat = 1.5
                        let iconSize = (r - inset) * 2
                        let rect = CGRect(x: p.x - iconSize / 2, y: p.y - iconSize / 2, width: iconSize, height: iconSize)
                        ctx.drawLayer { layer in
                            layer.clip(to: Path(ellipseIn: rect))
                            layer.draw(ctx.resolve(Image(nsImage: nsImage)), in: rect)
                        }
                    } else {
                        let letter = ctx.resolve(Text(String(meta.label.prefix(1)).uppercased()).font(.system(size: r * 0.8, weight: .bold)).foregroundColor(.white))
                        ctx.draw(letter, at: p)
                    }
                    if s > 1.1 || isActive {
                        ctx.draw(ctx.resolve(Text(meta.label).font(.system(size: 10)).foregroundColor(.white.opacity(0.6))),
                                 at: CGPoint(x: p.x, y: p.y + r + 11))
                    }
                case .hub(let tag):
                    let r: CGFloat = 30 * min(s, 1.6)
                    drawCircleNode(ctx, at: p, radius: r, active: isActive)
                    let label = ctx.resolve(
                        Text(tag.uppercased())
                            .font(.system(size: max(9, min(12, r * 0.34)), weight: .semibold))
                            .foregroundColor(.white)
                    )
                    ctx.draw(label, at: p)
                }
            }
        }
        .background(bg)
    }

    private func drawCircleNode(_ ctx: GraphicsContext, at p: CGPoint, radius r: CGFloat, active: Bool) {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(nodeFill))
        ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(active ? 0.95 : 0.7)), lineWidth: active ? 1.6 : 1.1)
    }

    // MARK: preview card

    private func previewCard(_ node: GraphNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(SourceInfo.meta(for: node).label).font(.caption.bold())
                Text("·").foregroundStyle(.tertiary)
                Text(node.createdAt.prefix(10)).font(.caption).foregroundStyle(.secondary)
            }
            if let thumb = node.thumb,
               let img = NSImage(contentsOf: Thumbnailer.thumbsDir.appendingPathComponent(thumb)) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(height: 120).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(previewText(node))
                .font(.callout)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !node.tags.isEmpty {
                Text(node.tags.prefix(4).map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(red: 0.14, green: 0.135, blue: 0.13), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }

    private func previewText(_ node: GraphNode) -> String {
        if let full = sim.fullContent[node.id] {
            // Strip the trailing context footer we append at save time.
            return full.components(separatedBy: "\n\n(Saved from").first ?? full
        }
        return node.summary.isEmpty ? node.title : node.summary
    }

    // MARK: chrome

    private var toolbar: some View {
        let memories = sim.bodies.filter { if case .memory = $0.node.kind { return true }; return false }.count
        return HStack(spacing: 12) {
            Text("MEMORY GRAPH").font(Theme.ui(10, .semibold)).kerning(1.5).foregroundStyle(Theme.ink(0.4))
            Rectangle().fill(Theme.line).frame(width: 1, height: 16)
            Text("\(memories) memories").font(Theme.mono(11)).foregroundStyle(Theme.ink(0.5))

            Spacer()

            Text("drag to pan · pinch to zoom · drag a node to arrange")
                .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.3))
            Picker("", selection: $sim.scope) {
                ForEach(GraphService.Scope.allCases, id: \.self) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .onChange(of: sim.scope) { sim.load(engine: engine) }
            Button { sim.load(engine: engine) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(Theme.ink(0.55)).help("Refresh")
        }
        .padding(.horizontal, 16).frame(height: 46)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func worldPoint(_ screen: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (screen.x - size.width / 2 - transform.pan.width) / transform.scale,
                y: (screen.y - size.height / 2 - transform.pan.height) / transform.scale)
    }

    /// Drag on a node → move & pin it. Drag on empty space → pan. A release
    /// with (almost) no movement → select the node under the cursor.
    private func boardDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if draggingNodeID == nil && dragStart == nil {
                    // Decide once, at the start of the drag.
                    if let n = sim.node(at: v.startLocation, transform: transform, in: size) {
                        draggingNodeID = n.id
                    } else {
                        dragStart = transform.pan
                    }
                }
                if let id = draggingNodeID {
                    sim.dragNode(id: id, to: worldPoint(v.location, size: size))
                } else {
                    transform.pan = CGSize(
                        width: (dragStart?.width ?? 0) + v.translation.width,
                        height: (dragStart?.height ?? 0) + v.translation.height
                    )
                }
            }
            .onEnded { v in
                let moved = hypot(v.translation.width, v.translation.height)
                if draggingNodeID == nil, moved < 4 {
                    // A tap → select.
                    let n = sim.node(at: v.location, transform: transform, in: size)
                    sim.selected = n
                    if case .memory(let m) = n?.kind { sim.ensureContent(for: m, engine: engine) }
                }
                draggingNodeID = nil
                dragStart = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if magnifyBase == nil { magnifyBase = transform.scale }
                transform.scale = min(max((magnifyBase ?? 1) * v.magnification, 0.3), 4)
            }
            .onEnded { _ in magnifyBase = nil }
    }
}
