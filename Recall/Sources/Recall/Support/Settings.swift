import Foundation

/// UserDefaults-backed settings.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var captureInterval: TimeInterval {
        didSet { d.set(captureInterval, forKey: "captureInterval") }
    }
    @Published var keepThumbnails: Bool {
        didSet { d.set(keepThumbnails, forKey: "keepThumbnails") }
    }
    @Published var thumbnailQuality: Double {
        didSet { d.set(thumbnailQuality, forKey: "thumbnailQuality") }
    }
    @Published var pauseOnLowBattery: Bool {
        didSet { d.set(pauseOnLowBattery, forKey: "pauseOnLowBattery") }
    }
    @Published var blockedApps: [String] {
        didSet { d.set(blockedApps, forKey: "blockedApps") }
    }
    @Published var blockedDomains: [String] {
        didSet { d.set(blockedDomains, forKey: "blockedDomains") }
    }

    @Published var supermemoryURL: String {
        didSet { d.set(supermemoryURL, forKey: "supermemoryURL") }
    }
    @Published var supermemoryKey: String {
        didSet { d.set(supermemoryKey, forKey: "supermemoryKey") }
    }
    @Published var ollamaURL: String {
        didSet { d.set(ollamaURL, forKey: "ollamaURL") }
    }
    @Published var ollamaModel: String {
        didSet { d.set(ollamaModel, forKey: "ollamaModel") }
    }
    @Published var containerTag: String {
        didSet { d.set(containerTag, forKey: "containerTag") }
    }
    @Published var thumbnailRetentionDays: Int {
        didSet { d.set(thumbnailRetentionDays, forKey: "thumbnailRetentionDays") }
    }
    @Published var autoStartMonitoring: Bool {
        didSet { d.set(autoStartMonitoring, forKey: "autoStartMonitoring") }
    }

    /// Deliberate "save this" memories live apart from passive screen memories.
    static let savedTag = "saved"

    var supermemoryURLValue: URL { URL(string: supermemoryURL) ?? URL(string: "http://localhost:6767")! }
    var ollamaURLValue: URL { URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")! }

    static let defaultBlockedApps = [
        "1password", "bitwarden", "keychain access", "com.apple.keychainaccess",
    ]
    static let defaultBlockedDomains = [
        "*.bank*", "accounts.google.com", "*.paypal.*", "signin", "checkout",
    ]

    init() {
        captureInterval = d.object(forKey: "captureInterval") as? TimeInterval ?? 5
        keepThumbnails = d.object(forKey: "keepThumbnails") as? Bool ?? true
        thumbnailQuality = d.object(forKey: "thumbnailQuality") as? Double ?? 0.4
        pauseOnLowBattery = d.object(forKey: "pauseOnLowBattery") as? Bool ?? true
        blockedApps = d.stringArray(forKey: "blockedApps") ?? Settings.defaultBlockedApps
        blockedDomains = d.stringArray(forKey: "blockedDomains") ?? Settings.defaultBlockedDomains
        supermemoryURL = d.string(forKey: "supermemoryURL") ?? "http://localhost:6767"
        supermemoryKey = d.string(forKey: "supermemoryKey") ?? ""
        ollamaURL = d.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        ollamaModel = d.string(forKey: "ollamaModel") ?? "qwen3:8b"
        containerTag = d.string(forKey: "containerTag") ?? "recall"
        thumbnailRetentionDays = d.object(forKey: "thumbnailRetentionDays") as? Int ?? 30
        autoStartMonitoring = d.object(forKey: "autoStartMonitoring") as? Bool ?? false
    }
}
