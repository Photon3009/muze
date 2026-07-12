import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

/// Orchestrates the capture pipeline:
/// capture → dedupe → context → privacy → OCR → store.
@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var isPaused = false
    @Published var isMonitoring = false
    @Published var pausedUntil: Date?
    @Published var hasScreenPermission = Permissions.screenRecordingGranted()
    @Published var hasAXPermission = Permissions.accessibilityGranted()
    @Published var stats = DayStats()
    @Published var lastKept: FrameRecord?
    @Published var supermemoryUp = false
    @Published var ollamaUp = false
    @Published var pendingCount = 0
    @Published var chatHotkeyLabel = "⌥Space"
    @Published var saveHotkeyLabel = "⌥S"

    let settings = Settings()
    private let capture = CaptureService()
    private let dedupe = DedupeService()
    private let context = ContextService()
    private let ocr = OCRService()
    private var privacy: PrivacyFilter { PrivacyFilter(settings: settings) }
    private lazy var ingest = IngestWorker(settings: settings)
    private var hotkey: HotKey?
    private var saveHotkey: HotKey?

    private var timer: Timer?
    private var healthTimer: Timer?
    private var ticking = false

    // One memory per app-session (Rewind-style), not per frame.
    private struct OpenSession {
        var appBundleID: String
        var frameIDs: [Int64] = []
        var startedAt = Date()
        var lastActivity = Date()
    }

    private var session: OpenSession?
    private let sessionIdleTimeout: TimeInterval = 300
    private let sessionMaxFrames = 40

    private func trackSession(frameID: Int64?, bundleID: String) {
        if var s = session {
            let switched = s.appBundleID != bundleID
            let idle = Date().timeIntervalSince(s.lastActivity) > sessionIdleTimeout
            let full = s.frameIDs.count >= sessionMaxFrames
            if switched || idle || full {
                closeSession()
            } else {
                if let id = frameID { s.frameIDs.append(id) }
                s.lastActivity = Date()
                session = s
                return
            }
        }
        var fresh = OpenSession(appBundleID: bundleID)
        if let id = frameID { fresh.frameIDs.append(id) }
        session = fresh
    }

    func closeSession() {
        guard let s = session, !s.frameIDs.isEmpty else {
            session = nil
            return
        }
        session = nil
        Task { await Store.shared.enqueueSession(frameIDs: s.frameIDs) }
    }

    func startIfPermitted() {
        hasScreenPermission = Permissions.screenRecordingGranted()
        hasAXPermission = Permissions.accessibilityGranted()
        if hasScreenPermission {
            // Passive monitoring is opt-in: only auto-start when enabled.
            if settings.autoStartMonitoring { start() }
        } else {
            // First run: trigger the system permission prompt; the menu bar
            // popover offers "Finish setup…" for the full onboarding flow.
            Permissions.requestScreenRecording()
        }
        refreshStats()

        // Queue drainer + service health polling + ⌥Space chat hotkey.
        Task { await ingest.start() }
        // Retention: thumbnails beyond N days are pruned (text kept forever).
        Task { await Store.shared.pruneThumbnails(olderThanDays: settings.thumbnailRetentionDays) }
        // Other apps (ChatGPT, Raycast, Alfred) often own ⌥Space — fall back
        // through alternatives and surface the winning combo in the menu.
        if let (hk, label) = HotKey.firstAvailable([
            (UInt32(kVK_Space), UInt32(optionKey), "⌥Space"),
            (UInt32(kVK_Space), UInt32(controlKey | optionKey), "⌃⌥Space"),
            (UInt32(kVK_Space), UInt32(optionKey | shiftKey), "⌥⇧Space"),
        ], handler: { [weak self] in
            guard let self else { return }
            ChatPanelController.shared.toggle(engine: self)
        }) {
            hotkey = hk
            chatHotkeyLabel = label
        } else {
            chatHotkeyLabel = "menu only"
        }

        if let (hk, label) = HotKey.firstAvailable([
            (UInt32(kVK_ANSI_S), UInt32(optionKey), "⌥S"),
            (UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey), "⌃⌥S"),
            (UInt32(kVK_ANSI_S), UInt32(optionKey | shiftKey), "⌥⇧S"),
        ], handler: { [weak self] in
            guard let self else { return }
            SavePanelController.shared.trigger(engine: self)
        }) {
            saveHotkey = hk
            saveHotkeyLabel = label
        } else {
            saveHotkeyLabel = "menu only"
        }
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollHealth() }
        }
        Task { await pollHealth() }
    }

    private func pollHealth() async {
        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        let ol = OllamaClient(baseURL: settings.ollamaURLValue, model: settings.ollamaModel)
        async let a = sm.isUp()
        async let b = ol.isUp()
        async let c = Store.shared.pendingCount()
        let (smUp, olUp, pending) = await (a, b, c)
        supermemoryUp = smUp
        ollamaUp = olUp
        pendingCount = pending
    }

    func start() {
        stop()
        let interval = settings.captureInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        isMonitoring = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        closeSession()
    }

    func toggleMonitoring() {
        isMonitoring ? stop() : start()
    }

    func pause(for duration: TimeInterval?) {
        isPaused = true
        pausedUntil = duration.map { Date().addingTimeInterval($0) }
    }

    func resume() {
        isPaused = false
        pausedUntil = nil
    }

    func restartTimer() {
        if isMonitoring { start() }
    }

    private func tick() {
        guard !ticking else { return }
        if let until = pausedUntil, Date() > until { resume() }
        guard !isPaused, hasScreenPermission else { return }
        // Skip when idle, screen locked, or (configurable) low battery.
        guard !SystemState.isIdle(threshold: 120), !SystemState.isScreenLocked() else {
            closeSession() // user walked away — the session is over
            return
        }
        if settings.pauseOnLowBattery, SystemState.isOnLowBattery(below: 0.2) { return }

        ticking = true
        Task {
            defer { Task { @MainActor in self.ticking = false } }
            await self.processFrame()
        }
    }

    private func processFrame() async {
        // Context first — cheap, and it decides privacy before pixels go anywhere.
        let ctx = await context.current()
        let filter = privacy
        if filter.isBlocked(bundleID: ctx.bundleID, appName: ctx.appName, windowTitle: ctx.windowTitle, url: ctx.url) {
            await Store.shared.bumpStat(\.blocked)
            await refreshStatsAsync()
            return
        }

        guard let image = await capture.captureActiveDisplay() else { return }
        await Store.shared.bumpStat(\.captured)

        guard let hash = dedupe.dHash(of: image) else { return }
        if dedupe.isDuplicate(hash) {
            await Store.shared.bumpStat(\.deduped)
            // Static screen still counts as activity in the current session.
            await MainActor.run { self.trackSession(frameID: nil, bundleID: ctx.bundleID) }
            await refreshStatsAsync()
            return
        }

        let text = await ocr.recognize(image: image, minConfidence: 0.3)

        // Scroll-merge: same app+window and near-identical text → update last row.
        if let last = await Store.shared.lastFrame(),
           let lastID = last.id,
           last.appBundleID == ctx.bundleID,
           last.windowTitle == ctx.windowTitle,
           TextSimilarity.jaccard(text, last.ocrText) > 0.95 {
            await Store.shared.touchLastSeen(frameID: lastID)
            dedupe.remember(hash)
            await refreshStatsAsync()
            return
        }

        dedupe.remember(hash)
        var thumbPath: String?
        if settings.keepThumbnails {
            thumbPath = Thumbnailer.save(image: image, quality: settings.thumbnailQuality)
        }

        let frame = FrameRecord(
            id: nil,
            capturedAt: Date(),
            lastSeenAt: Date(),
            appBundleID: ctx.bundleID,
            appName: ctx.appName,
            windowTitle: ctx.windowTitle,
            url: ctx.url,
            phash: Int64(bitPattern: hash),
            ocrText: text,
            thumbPath: thumbPath,
            supermemoryDocID: nil
        )
        let saved = await Store.shared.insertFrame(frame)
        if let savedID = saved.id {
            await MainActor.run { self.trackSession(frameID: savedID, bundleID: ctx.bundleID) }
        }
        await Store.shared.bumpStat(\.kept)
        await MainActor.run { self.lastKept = saved }
        await refreshStatsAsync()
    }

    func refreshStats() {
        Task { await refreshStatsAsync() }
    }

    private func refreshStatsAsync() async {
        let s = await Store.shared.todayStats()
        await MainActor.run { self.stats = s }
    }

}
