import AppKit
import ApplicationServices

struct CaptureContext {
    var bundleID: String
    var appName: String
    var windowTitle: String
    var url: String?
}

/// Frontmost app (NSWorkspace), window title (Accessibility), browser URL (AppleScript).
final class ContextService {
    private let browserScripts: [String: String] = [
        "com.google.Chrome": #"tell application "Google Chrome" to get URL of active tab of front window"#,
        "com.brave.Browser": #"tell application "Brave Browser" to get URL of active tab of front window"#,
        "company.thebrowser.Browser": #"tell application "Arc" to get URL of active tab of front window"#,
        "com.apple.Safari": #"tell application "Safari" to get URL of front document"#,
        "com.microsoft.edgemac": #"tell application "Microsoft Edge" to get URL of active tab of front window"#,
    ]

    func current() async -> CaptureContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? "unknown"
        let appName = app?.localizedName ?? "Unknown"
        let title = app.map { focusedWindowTitle(pid: $0.processIdentifier) } ?? ""
        var url: String?
        if let script = browserScripts[bundleID] {
            url = await runAppleScript(script)
            if let u = url, !u.hasPrefix("http") { url = nil }
        }
        return CaptureContext(bundleID: bundleID, appName: appName, windowTitle: title, url: url)
    }

    private func focusedWindowTitle(pid: pid_t) -> String {
        let appEl = AXUIElementCreateApplication(pid)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window else { return "" }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return ""
        }
        return (title as? String) ?? ""
    }

    private func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)
                cont.resume(returning: error == nil ? result?.stringValue : nil)
            }
        }
    }
}
