import SwiftUI

@main
struct UncommittedApp: App {
    @StateObject private var configStore: ConfigStore
    @StateObject private var repoStore: RepoStore

    init() {
        let config = ConfigStore()
        _configStore = StateObject(wrappedValue: config)
        _repoStore = StateObject(wrappedValue: RepoStore(configStore: config))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(configStore)
                .environmentObject(repoStore)
        } label: {
            MenuBarLabel(store: repoStore)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(configStore)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: RepoStore

    var body: some View {
        let total = store.totalDirty
        if total > 0 {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                Text("\(total)")
            }
        } else {
            Image(systemName: "checkmark.circle")
        }
    }
}
