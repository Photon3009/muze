import CoreText
import SwiftUI
import UserNotifications

@main
struct MuzeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = Engine.shared

    var body: some Scene {
        // No MenuBarExtra and no auto-opening Window — Muze is a normal windowed
        // app whose windows are managed imperatively by AppDelegate (onboarding
        // on first run, otherwise the main window). A Settings scene keeps the
        // App valid without popping a window at launch.
        SwiftUI.Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular dock app (no menu-bar icon). Gives a dock icon + Cmd-Q.
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        Self.registerBundledFonts()
        Engine.shared.startIfPermitted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // First run (no Screen Recording yet) → themed onboarding.
            // Otherwise straight into the app.
            if Permissions.screenRecordingGranted() {
                MainWindowController.shared.show(engine: Engine.shared)
            } else {
                OnboardingWindowController.shared.show(engine: Engine.shared)
            }
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
            if Permissions.screenRecordingGranted() {
                MainWindowController.shared.show(engine: Engine.shared)
            } else {
                OnboardingWindowController.shared.show(engine: Engine.shared)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush the open session so its frames aren't orphaned.
        Engine.shared.closeSession()
        Thread.sleep(forTimeInterval: 0.3) // let the enqueue write commit
    }

    /// Show goal notifications even while Muze is the foreground app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
