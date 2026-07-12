import AppKit

/// Tracks per-app foreground time using the native frontmost-app signal —
/// independent of screen monitoring/captures. Accrues elapsed time to whatever
/// app is in front, pausing while the user is idle or the screen is locked.
/// No special permission required (NSWorkspace is public API).
@MainActor
final class ActivityTracker {
    private var timer: Timer?
    private var lastTick: Date?
    private let settings: Settings
    private let interval: TimeInterval = 8

    init(settings: Settings) { self.settings = settings }

    func start() {
        stop()
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Also settle time immediately when the user switches apps.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appSwitched),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func appSwitched() { tick() }

    // Browsers whose foreground time we split by the active tab's site.
    private let browserScripts: [String: String] = [
        "com.google.Chrome": #"tell application "Google Chrome" to get URL of active tab of front window"#,
        "com.brave.Browser": #"tell application "Brave Browser" to get URL of active tab of front window"#,
        "company.thebrowser.Browser": #"tell application "Arc" to get URL of active tab of front window"#,
        "com.apple.Safari": #"tell application "Safari" to get URL of front document"#,
        "com.microsoft.edgemac": #"tell application "Microsoft Edge" to get URL of active tab of front window"#,
    ]

    private func tick() {
        // Pause on idle / locked so background time isn't counted.
        guard !SystemState.isIdle(threshold: 120), !SystemState.isScreenLocked() else {
            lastTick = nil
            return
        }
        let now = Date()
        // Real elapsed since last tick (capped, so sleep/coalescing can't spike it).
        let elapsed = min(lastTick.map { now.timeIntervalSince($0) } ?? interval, 30)
        lastTick = now
        guard elapsed > 0.5,
              let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else { return }
        let bundleID = app.bundleIdentifier ?? ""
        let filter = PrivacyFilter(settings: settings)

        // For browsers, attribute time to the active tab's SITE (e.g.
        // "youtube.com"), not the browser itself.
        if let script = browserScripts[bundleID] {
            Task {
                let url = await Self.runScript(script)
                let host = Self.siteLabel(from: url)
                let label = host ?? name
                if filter.isBlocked(bundleID: bundleID, appName: name, windowTitle: "", url: url) { return }
                await Store.shared.addAppTime(app: label, seconds: elapsed)
            }
            return
        }

        if filter.isBlocked(bundleID: bundleID, appName: name, windowTitle: "", url: nil) { return }
        Task { await Store.shared.addAppTime(app: name, seconds: elapsed) }
    }

    /// "https://www.youtube.com/watch?..." → "youtube.com" (nil if not web).
    private static func siteLabel(from url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private static func runScript(_ source: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var err: NSDictionary?
                let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
                cont.resume(returning: err == nil ? out?.stringValue : nil)
            }
        }
    }
}
