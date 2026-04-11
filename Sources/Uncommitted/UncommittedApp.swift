import SwiftUI

@main
struct UncommittedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.configStore)
        }
        .windowResizability(.contentSize)
    }
}
