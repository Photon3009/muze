import Foundation

/// Hard privacy gate. Anything matching is discarded BEFORE OCR and never
/// persisted anywhere — not the DB, not the queue.
struct PrivacyFilter {
    let settings: Settings

    func isBlocked(bundleID: String, appName: String, windowTitle: String, url: String?) -> Bool {
        let bid = bundleID.lowercased()
        let name = appName.lowercased()
        let title = windowTitle.lowercased()
        for pattern in settings.blockedApps {
            let p = pattern.lowercased()
            if p.isEmpty { continue }
            if bid.contains(p) || name.contains(p) || title.contains(p) { return true }
        }
        if let url = url?.lowercased() {
            guard let host = URL(string: url)?.host?.lowercased() else { return false }
            for pattern in settings.blockedDomains {
                let p = pattern.lowercased().trimmingCharacters(in: .whitespaces)
                if p.isEmpty { continue }
                // "*.bank*" style globs → substring match on host
                let needle = p.replacingOccurrences(of: "*", with: "")
                if !needle.isEmpty, host.contains(needle) { return true }
            }
        }
        return false
    }
}
