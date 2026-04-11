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
        .windowResizability(.contentSize)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: RepoStore

    var body: some View {
        let uncommitted = store.totalUncommitted
        let unpushed = store.totalUnpushed

        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
            if uncommitted > 0 {
                Text("\(uncommitted)")
            }
            if unpushed > 0 {
                Text("↑\(unpushed)")
            }
        }
    }
}
