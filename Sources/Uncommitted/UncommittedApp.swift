import SwiftUI
import UncommittedCore

@main
struct UncommittedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.configStore)
                .environmentObject(appDelegate.repoStore)
                .environmentObject(appDelegate.fetchStateStore)
        }
        .windowResizability(.contentSize)
        // macOS 27 brings the Settings window back on the next launch when
        // it was open at quit, and shows it on a launch that opens nothing
        // else. Neither is wanted for a menu bar app. Both modifiers need
        // macOS 15, which is why the deployment target is 15.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
    }
}
