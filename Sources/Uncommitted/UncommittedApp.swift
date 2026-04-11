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

        if uncommitted == 0 && unpushed == 0 {
            Image(systemName: "checkmark")
        } else {
            HStack(spacing: 6) {
                if uncommitted > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "pencil")
                        Text("\(uncommitted)")
                    }
                }
                if unpushed > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                        Text("\(unpushed)")
                    }
                }
            }
        }
    }
}
