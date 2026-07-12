import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var engine: Engine
    @State private var timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("🧠 Recall").font(.largeTitle.bold())
                Text("Your screen, remembered. Everything stays on this Mac.")
                    .foregroundStyle(.secondary)
            }

            permissionRow(
                title: "Screen Recording",
                detail: "Required to capture frames. Without it Recall sees only your wallpaper.",
                granted: engine.hasScreenPermission,
                request: {
                    Permissions.requestScreenRecording()
                    Permissions.openScreenRecordingSettings()
                }
            )

            permissionRow(
                title: "Accessibility",
                detail: "Reads the focused window's title so memories know what you were doing.",
                granted: engine.hasAXPermission,
                request: {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            )

            Text("After granting Screen Recording, macOS requires Recall to be relaunched.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Relaunch Recall") { relaunch() }
                if engine.hasScreenPermission {
                    Button("Start capturing") {
                        engine.startIfPermitted()
                        NSApp.keyWindow?.close()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onReceive(timer) { _ in
            engine.hasScreenPermission = Permissions.screenRecordingGranted()
            engine.hasAXPermission = Permissions.accessibilityGranted()
        }
    }

    private func permissionRow(title: String, detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…") { request() }
            }
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
