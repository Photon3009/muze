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
    @Published var llmProvider: String {
        didSet { d.set(llmProvider, forKey: "llmProvider") }
    }
    @Published var cloudAPIKey: String {
        didSet { d.set(cloudAPIKey, forKey: "cloudAPIKey") }
    }
    @Published var cloudModel: String {
        didSet { d.set(cloudModel, forKey: "cloudModel") }
    }
    @Published var cloudBaseURL: String {
        didSet { d.set(cloudBaseURL, forKey: "cloudBaseURL") }
    }
    @Published var engineAutoStart: Bool {
        didSet { d.set(engineAutoStart, forKey: "engineAutoStart") }
    }
    @Published var engineBinary: String {
        didSet { d.set(engineBinary, forKey: "engineBinary") }
    }
    /// The engine keeps its database relative to its working directory —
    /// this must stay pointed at the folder that holds `.supermemory/`.
    @Published var engineWorkdir: String {
        didSet { d.set(engineWorkdir, forKey: "engineWorkdir") }
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
    /// Labels (app names or site hosts, lowercased) that count as distractions
    /// for the Focus tab. User-editable from the Focus view.
    @Published var distractingLabels: [String] {
        didSet { d.set(distractingLabels, forKey: "distractingLabels") }
    }
    /// Eyes-on-screen: use brief on-device webcam checks while input-idle to
    /// tell watching (focus) from wandering (Off-screen distraction). Opt-in.
    @Published var gazeCheckEnabled: Bool {
        didSet { d.set(gazeCheckEnabled, forKey: "gazeCheckEnabled") }
    }

    /// Deliberate "save this" memories live apart from passive screen memories.
    static let savedTag = "saved"

    var supermemoryURLValue: URL { URL(string: supermemoryURL) ?? URL(string: "http://localhost:6767")! }
    var ollamaURLValue: URL { URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")! }
    var cloudBaseURLValue: URL { URL(string: cloudBaseURL) ?? URL(string: "https://api.openai.com/v1")! }

    var llmProviderValue: LLMProvider { LLMProvider(rawValue: llmProvider) ?? .ollama }

    /// The model backend everything (enrichment, tagging, chat) should use.
    var llm: LLMClient {
        switch llmProviderValue {
        case .ollama:
            return .ollama(OllamaClient(baseURL: ollamaURLValue, model: ollamaModel))
        case .openai:
            return .openAI(OpenAIChatClient(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: cloudAPIKey, model: cloudModel))
        case .anthropic:
            return .anthropic(AnthropicClient(apiKey: cloudAPIKey, model: cloudModel))
        case .custom:
            return .openAI(OpenAIChatClient(baseURL: cloudBaseURLValue, apiKey: cloudAPIKey, model: cloudModel))
        }
    }

    static let defaultBlockedApps = [
        "1password", "bitwarden", "keychain access", "com.apple.keychainaccess",
    ]
    static let defaultBlockedDomains = [
        "*.bank*", "accounts.google.com", "*.paypal.*", "signin", "checkout",
    ]

    static let defaultDistractingLabels = [
        "youtube.com", "x.com", "twitter.com", "instagram.com", "reddit.com",
        "facebook.com", "tiktok.com", "netflix.com", "twitch.tv", "primevideo.com",
        "linkedin.com", "news.ycombinator.com",
        "whatsapp", "telegram", "discord", "messages",
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
        llmProvider = d.string(forKey: "llmProvider") ?? LLMProvider.ollama.rawValue
        cloudAPIKey = d.string(forKey: "cloudAPIKey") ?? ""
        cloudModel = d.string(forKey: "cloudModel") ?? ""
        cloudBaseURL = d.string(forKey: "cloudBaseURL") ?? "https://api.openai.com/v1"
        engineAutoStart = d.object(forKey: "engineAutoStart") as? Bool ?? true
        engineBinary = d.string(forKey: "engineBinary") ?? "~/.local/bin/supermemory-server"
        engineWorkdir = d.string(forKey: "engineWorkdir") ?? ""
        containerTag = d.string(forKey: "containerTag") ?? "recall"
        thumbnailRetentionDays = d.object(forKey: "thumbnailRetentionDays") as? Int ?? 30
        autoStartMonitoring = d.object(forKey: "autoStartMonitoring") as? Bool ?? false
        distractingLabels = d.stringArray(forKey: "distractingLabels") ?? Settings.defaultDistractingLabels
        gazeCheckEnabled = d.object(forKey: "gazeCheckEnabled") as? Bool ?? false
    }
}
