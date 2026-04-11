import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            RepositoriesSettingsView()
                .tabItem { Label("Repositories", systemImage: "folder") }
        }
        .frame(width: 520, height: 380)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Repository click action") {
                Picker("Open with", selection: $configStore.config.clickAction) {
                    ForEach(ClickAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }

                if configStore.config.clickAction == .custom {
                    TextField(
                        "Command",
                        text: $configStore.config.customCommand,
                        prompt: Text("open -a Ghostty {path}")
                    )
                    .textFieldStyle(.roundedBorder)
                    LabeledContent("") {
                        Text("Use `{path}` as the repository path placeholder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch Uncommitted at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Repositories

struct RepositoriesSettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var selection: Source.ID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                if configStore.config.sources.isEmpty {
                    Text("No source folders. Click the + button below to add one.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                } else {
                    ForEach(configStore.config.sources) { source in
                        SourceRow(source: source)
                            .tag(source.id)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 4) {
                Button(action: addSource) {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Add a folder (single repo or a container to scan)")

                Button(action: removeSelected) {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .help("Remove the selected folder")

                Spacer()

                Text("Folders with a `.git` directory are added as single repositories. Folders without one are scanned one level deep for child repos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
            }
            .padding(10)
        }
    }

    private func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a repository or a folder containing repositories"

        if panel.runModal() == .OK, let url = panel.url {
            configStore.addSource(path: url.path)
        }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        configStore.removeSource(id: id)
        selection = nil
    }
}

struct SourceRow: View {
    let source: Source

    private var expandedPath: String {
        (source.path as NSString).abbreviatingWithTildeInPath
    }

    private var isRepo: Bool {
        FileManager.default.fileExists(
            atPath: (source.path as NSString).appendingPathComponent(".git")
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isRepo ? "arrow.triangle.branch" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(expandedPath)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isRepo ? "Repository" : "Source folder (scanned one level deep)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
