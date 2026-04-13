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
    }
}
