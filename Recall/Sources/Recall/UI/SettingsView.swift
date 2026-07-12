import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @State private var blockedAppsText = ""
    @State private var blockedDomainsText = ""
    @State private var dbSize: Int64 = 0
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var forgetFrom = Calendar.current.date(byAdding: .hour, value: -1, to: Date())!
    @State private var forgetTo = Date()
    @State private var forgetResult: String?

    private func exportAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "recall-export.jsonl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { try? await Store.shared.exportJSONL(to: url) }
    }

    private func forgetRange() {
        let from = forgetFrom, to = forgetTo
        let settings = engine.settings
        Task {
            let docIDs = await Store.shared.forgetFrames(from: from, to: to)
            // Best-effort delete from the engine as well.
            for id in docIDs {
                var req = URLRequest(url: settings.supermemoryURLValue.appendingPathComponent("v3/documents/\(id)"))
                req.httpMethod = "DELETE"
                _ = try? await URLSession.shared.data(for: req)
            }
            await MainActor.run {
                forgetResult = "Forgot \(docIDs.count) ingested + local memories in range."
                engine.refreshStats()
            }
        }
    }

    var body: some View {
        Form {
            Section("Capture") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.settings.captureInterval },
                        set: { engine.settings.captureInterval = $0; engine.restartTimer() }
                    ), in: 2...30, step: 1)
                    Text("every \(Int(engine.settings.captureInterval))s").monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
                Toggle("Keep thumbnails (timeline previews)", isOn: Binding(
                    get: { engine.settings.keepThumbnails },
                    set: { engine.settings.keepThumbnails = $0 }
                ))
                Toggle("Pause on battery below 20%", isOn: Binding(
                    get: { engine.settings.pauseOnLowBattery },
                    set: { engine.settings.pauseOnLowBattery = $0 }
                ))
            }

            Section("Privacy — never captured") {
                VStack(alignment: .leading) {
                    Text("Blocked apps / window titles (one per line)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $blockedAppsText).font(.body.monospaced()).frame(height: 70)
                }
                VStack(alignment: .leading) {
                    Text("Blocked URL domains (one per line, * wildcards)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $blockedDomainsText).font(.body.monospaced()).frame(height: 70)
                }
                Button("Save blocklists") {
                    engine.settings.blockedApps = blockedAppsText.split(separator: "\n").map(String.init)
                    engine.settings.blockedDomains = blockedDomainsText.split(separator: "\n").map(String.init)
                }
            }

            Section("Services") {
                TextField("supermemory URL", text: Binding(
                    get: { engine.settings.supermemoryURL }, set: { engine.settings.supermemoryURL = $0 }))
                TextField("Ollama URL", text: Binding(
                    get: { engine.settings.ollamaURL }, set: { engine.settings.ollamaURL = $0 }))
                TextField("Ollama model", text: Binding(
                    get: { engine.settings.ollamaModel }, set: { engine.settings.ollamaModel = $0 }))
                HStack {
                    Circle().fill(engine.supermemoryUp ? .green : .red).frame(width: 8, height: 8)
                    Text("supermemory")
                    Circle().fill(engine.ollamaUp ? .green : .red).frame(width: 8, height: 8)
                    Text("ollama")
                }.font(.caption)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in LoginItem.set(v) }
                Stepper("Keep thumbnails for \(engine.settings.thumbnailRetentionDays) days", value: Binding(
                    get: { engine.settings.thumbnailRetentionDays },
                    set: { engine.settings.thumbnailRetentionDays = $0 }
                ), in: 1...365)
                Button("Export all memories (JSONL)…") { exportAll() }
            }

            Section("Forget a time range") {
                DatePicker("From", selection: $forgetFrom)
                DatePicker("To", selection: $forgetTo)
                Button("Forget this range", role: .destructive) { forgetRange() }
                if let msg = forgetResult { Text(msg).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Today") {
                LabeledContent("Frames captured", value: "\(engine.stats.captured)")
                LabeledContent("Deduplicated", value: "\(engine.stats.deduped) (\(Int(engine.stats.dedupeRate * 100))%)")
                LabeledContent("Memories kept", value: "\(engine.stats.kept)")
                LabeledContent("Privacy-blocked", value: "\(engine.stats.blocked)")
                LabeledContent("Database size", value: ByteCountFormatter.string(fromByteCount: dbSize, countStyle: .file))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .onAppear {
            blockedAppsText = engine.settings.blockedApps.joined(separator: "\n")
            blockedDomainsText = engine.settings.blockedDomains.joined(separator: "\n")
            Task { dbSize = await Store.shared.databaseSizeBytes() }
        }
    }
}
