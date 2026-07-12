import Foundation

/// Boots the local services Muze depends on when they aren't running, so
/// memories don't "vanish" after a reboot just because the supermemory
/// engine was never started. The engine stores its data relative to its
/// working directory, so it must always be launched from the same folder
/// (Settings → engine folder) — starting it anywhere else would come up
/// with an empty database.
enum ServiceLauncher {
    private static var lastAttempt = Date.distantPast

    /// Called at launch and from the health poll. Throttled so a dead or
    /// crashing binary doesn't get respawned every poll tick.
    static func startIfNeeded(settings: Settings) async {
        guard settings.engineAutoStart else { return }
        guard Date().timeIntervalSince(lastAttempt) > 30 else { return }
        lastAttempt = Date()

        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        if !(await sm.isUp()), !settings.engineWorkdir.isEmpty {
            spawn(binary: settings.engineBinary, cwd: settings.engineWorkdir, log: "muze-engine.log")
        }

        if settings.llmProviderValue == .ollama {
            let ollama = OllamaClient(baseURL: settings.ollamaURLValue, model: settings.ollamaModel)
            if !(await ollama.isUp()),
               let bin = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
                   .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                spawn(binary: bin, args: ["serve"], cwd: nil, log: "muze-ollama.log")
            }
        }
    }

    private static func spawn(binary: String, args: [String] = [], cwd: String?, log: String) {
        let path = (binary as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        if let cwd, !cwd.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath, isDirectory: true)
        }

        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(log)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        proc.standardOutput = handle
        proc.standardError = handle
        try? proc.run()
    }
}
