import CoreText
import SwiftUI

@main
struct MuzeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = Engine.shared

    var body: some Scene {
        // No MenuBarExtra — Muze is a normal windowed app (dock icon), not a
        // menu-bar app. The main window is managed by MainWindowController.
        Window("Welcome to Muze", id: "onboarding") {
            OnboardingView().environmentObject(engine)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular dock app (no menu-bar icon). Gives a dock icon + Cmd-Q.
        NSApp.setActivationPolicy(.regular)
        Self.registerBundledFonts()
        Engine.shared.startIfPermitted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainWindowController.shared.show(engine: Engine.shared)
        }
    }

    /// Register bundled TTFs explicitly (ATSApplicationFontsPath is flaky for
    /// accessory / ad-hoc-signed apps, so Ovo would silently fall back to SF).
    static func registerBundledFonts() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Clicking the app icon (Dock/Launchpad/Finder) while running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            MainWindowController.shared.show(engine: Engine.shared)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush the open session so its frames aren't orphaned.
        Engine.shared.closeSession()
        Thread.sleep(forTimeInterval: 0.3) // let the enqueue write commit
    }
}
