import SwiftUI

@main
struct RecallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = Engine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(engine)
        } label: {
            Image(systemName: engine.isPaused ? "brain.head.profile" : "brain.head.profile.fill")
        }
        .menuBarExtraStyle(.window)

        Window("Recall Settings", id: "settings") {
            SettingsView().environmentObject(engine)
        }
        .windowResizability(.contentSize)

        Window("Welcome to Recall", id: "onboarding") {
            OnboardingView().environmentObject(engine)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Engine.shared.startIfPermitted()
        // Launched by hand (icon click) → open the app window. Login-item
        // launches stay quiet in the menu bar.
        if !LoginItem.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainWindowController.shared.show(engine: Engine.shared)
            }
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
