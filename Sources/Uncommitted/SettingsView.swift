import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            RepositoriesSettingsView()
                .tabItem { Label("Repositories", systemImage: "folder") }

            ActionsSettingsView()
                .tabItem { Label("Actions", systemImage: "cursorarrow.rays") }

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 560)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Hide repositories with no changes", isOn: $configStore.config.hideCleanRepos)
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
        .frame(width: 560, height: 260)
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
                        .padding(.vertical, 28)
                } else {
                    ForEach($configStore.config.sources) { $source in
                        SourceRow(source: $source)
                            .tag(source.id)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 4) {
                Button(action: addSource) {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Add a folder")

                Button(action: removeSelected) {
                    Image(systemName: "minus").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .help("Remove the selected folder")

                Spacer()

                Text("Scan depth controls how many directory levels to search for `.git`. Scanning stops at each repo found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
            }
            .padding(10)
        }
        .frame(width: 560, height: 420)
    }

    private func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a repository or a folder containing repositories"

        if panel.runModal() == .OK, let url = panel.url {
            // If the chosen folder is itself a git repo, default depth to 0; otherwise 1.
            let isRepo = FileManager.default.fileExists(
                atPath: url.appendingPathComponent(".git").path
            )
            configStore.addSource(path: url.path, scanDepth: isRepo ? 0 : 1)
        }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        configStore.removeSource(id: id)
        selection = nil
    }
}

struct SourceRow: View {
    @Binding var source: Source

    private var displayPath: String {
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
                Text(displayPath)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isRepo
                     ? "Repository"
                     : "Source folder · scanning \(source.scanDepth) level\(source.scanDepth == 1 ? "" : "s") deep")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Depth", selection: $source.scanDepth) {
                ForEach(0...5, id: \.self) { depth in
                    Text("\(depth)").tag(depth)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 60)
            .help("How many levels deep to scan for .git directories")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Actions

struct ActionsSettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var selection: Action.ID?

    private var selectedIndex: Int? {
        guard let id = selection else { return nil }
        return configStore.config.actions.firstIndex(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach($configStore.config.actions) { $action in
                        ActionRow(action: action, isDefault: $action.wrappedValue.id == configStore.config.actions.first?.id)
                            .tag(action.id)
                    }
                    .onMove { from, to in
                        configStore.config.actions.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.inset)

                Divider()

                HStack(spacing: 4) {
                    Menu {
                        Button("Add Application…", action: addApp)
                        Button("Add Custom Command…", action: addCommand)
                        Button("Add Finder") {
                            configStore.config.actions.append(
                                Action(name: "Finder", kind: .finder)
                            )
                        }
                    } label: {
                        Image(systemName: "plus").frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button(action: removeSelected) {
                        Image(systemName: "minus").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil || configStore.config.actions.count <= 1)

                    Button {
                        moveSelection(by: -1)
                    } label: {
                        Image(systemName: "arrow.up").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled((selectedIndex ?? 0) <= 0)

                    Button {
                        moveSelection(by: 1)
                    } label: {
                        Image(systemName: "arrow.down").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedIndex == nil || selectedIndex == configStore.config.actions.count - 1)

                    Spacer()

                    Text("First action is the default — clicking a repo uses it. Right-click for the full list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                .padding(10)
            }
            .frame(width: 320)

            Divider()

            // Detail pane
            Group {
                if let index = selectedIndex {
                    ActionDetailView(action: $configStore.config.actions[index])
                } else {
                    VStack {
                        Text("Select an action")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 260)
        }
        .frame(width: 580, height: 420)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"

        if panel.runModal() == .OK, let url = panel.url {
            let name = url.deletingPathExtension().lastPathComponent
            let action = Action(name: name, kind: .app(name))
            configStore.config.actions.append(action)
            selection = action.id
        }
    }

    private func addCommand() {
        let action = Action(name: "New command", kind: .command("open -a Terminal {path}"))
        configStore.config.actions.append(action)
        selection = action.id
    }

    private func removeSelected() {
        guard let id = selection else { return }
        configStore.config.actions.removeAll { $0.id == id }
        selection = nil
    }

    private func moveSelection(by offset: Int) {
        guard let index = selectedIndex else { return }
        let newIndex = index + offset
        guard newIndex >= 0 && newIndex < configStore.config.actions.count else { return }
        // `move(fromOffsets:toOffset:)` uses insertion indices — moving down needs +1.
        let insertion = offset < 0 ? newIndex : newIndex + 1
        configStore.config.actions.move(fromOffsets: IndexSet(integer: index), toOffset: insertion)
    }
}

struct ActionRow: View {
    let action: Action
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.name)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isDefault {
                Text("Default")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.accentColor)
                    )
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var iconView: some View {
        if let nsImage = AppIcons.icon(for: action) {
            Image(nsImage: nsImage).resizable()
        } else {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        switch action.kind {
        case .finder: return "Open in Finder"
        case .app(let name): return "Application: \(name)"
        case .command(let cmd): return cmd
        }
    }
}

struct ActionDetailView: View {
    @Binding var action: Action

    var body: some View {
        Form {
            Section("Name") {
                TextField("", text: $action.name)
                    .textFieldStyle(.roundedBorder)
            }

            switch action.kind {
            case .finder:
                Section {
                    Text("Opens the repository in Finder. No configuration.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

            case .app(let appName):
                Section("Application") {
                    LabeledContent("Opens with") {
                        Text(appName).foregroundStyle(.secondary)
                    }
                    Text("Uses `/usr/bin/open -a \"\(appName)\"`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .command(let command):
                Section("Command") {
                    TextField(
                        "Shell command",
                        text: Binding(
                            get: { command },
                            set: { action.kind = .command($0) }
                        ),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3, reservesSpace: true)

                    Text("Runs with `/bin/zsh -l -c …`. Use `{path}` as the repository path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "?"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(.top, 12)

            Text("Uncommitted")
                .font(.title.weight(.semibold))

            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(bundleID)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            Text("A native menubar app for tracking uncommitted and unpushed changes across your git repositories.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text("Built with SwiftUI.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(width: 420, height: 340)
    }
}
