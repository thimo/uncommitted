import SwiftUI

@main
struct UncommittedApp: App {
    @StateObject private var store = RepoStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
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
