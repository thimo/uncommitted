import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import UncommittedCore

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
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var autoCheckForUpdates: Bool = true
    @State private var autoDownloadUpdates: Bool = false

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Count", selection: $configStore.config.menuBarLabelStyle) {
                    ForEach(MenuBarLabelStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle("Hide clean repositories", isOn: $configStore.config.hideCleanRepos)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: $launchAtLogin)
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

            Section {
                Toggle("Auto-fetch from remotes", isOn: $configStore.config.fetchFromRemotes)
            } header: {
                Text("Refresh")
            } footer: {
                Text("Periodically run `git fetch` in the background so the unpulled count stays current. Active repos refresh daily, idle repos weekly. Failures back off automatically; chronically failing repos are marked in the popup. Manual fetches via Option-click or right-click work regardless of this setting.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.60))
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoCheckForUpdates)
                    .onChange(of: autoCheckForUpdates) { _, newValue in
                        AppDelegate.shared?.updaterController.updater.automaticallyChecksForUpdates = newValue
                    }
                Toggle("Download and install automatically", isOn: $autoDownloadUpdates)
                    .onChange(of: autoDownloadUpdates) { _, newValue in
                        AppDelegate.shared?.updaterController.updater.automaticallyDownloadsUpdates = newValue
                    }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if let updater = AppDelegate.shared?.updaterController.updater {
                autoCheckForUpdates = updater.automaticallyChecksForUpdates
                autoDownloadUpdates = updater.automaticallyDownloadsUpdates
            }
        }
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
                        .foregroundStyle(.primary.opacity(0.70))
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

                Text("Scan depth = levels of subdirectories to search for `.git`. Scanning stops at each repo found.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.70))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
                .foregroundStyle(.primary.opacity(0.70))
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
                    .foregroundStyle(.primary.opacity(0.70))
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach($configStore.config.actions) { $action in
                        ActionRow(action: action, isDefault: $action.wrappedValue.id == configStore.config.actions.first?.id)
                            .tag(action.id)
                    }
                    .onMove { from, to in
                        configStore.config.actions.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .environment(\.defaultMinListRowHeight, 38)
                .frame(width: 280)

                Divider()

                // Detail pane
                Group {
                    if let index = selectedIndex {
                        ActionDetailView(action: $configStore.config.actions[index])
                    } else {
                        VStack {
                            Text("Select an action")
                                .foregroundStyle(.primary.opacity(0.70))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            Divider()

            // Full-width bottom toolbar
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

                Spacer()

                Text("Top action runs on click. Right-click shows all. Drag rows to reorder.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.70))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 560, height: 440)
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
                    .foregroundStyle(.primary.opacity(0.70))
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
                .foregroundStyle(.primary.opacity(0.70))
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
        VStack(alignment: .leading, spacing: 20) {
            section(title: "Name") {
                TextField("Action name", text: $action.name)
                    .textFieldStyle(.roundedBorder)
            }

            switch action.kind {
            case .finder:
                section(title: "Type") {
                    Text("Opens the repository in Finder.")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.70))
                }

            case .app(let appName):
                section(title: "Application") {
                    HStack(spacing: 8) {
                        if let nsImage = AppIcons.icon(forApp: appName) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .frame(width: 18, height: 18)
                        }
                        Text(appName)
                            .font(.body)
                    }
                    Text("Uses `/usr/bin/open -a \"\(appName)\"`")
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.70))
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }

            case .command(let command):
                section(title: "Command") {
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
                        .foregroundStyle(.primary.opacity(0.70))
                        .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.70))
            content()
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var buildDateString: String {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let date = attrs[.modificationDate] as? Date else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy 'at' HH:mm"
        return "Built \(formatter.string(from: date))"
    }

    // Datadog-sampled palette (#E00090 pink, #8900D2 purple, #4F00FF
    // blue-violet), swept around the glyph so each of the three ring
    // nodes lands in its own color: pink top-left, purple top-right,
    // blue bottom. Angular positions (SwiftUI: 0° = right, clockwise):
    //   90°  = bottom node  → blue
    //   210° = top-left     → pink
    //   330° = top-right    → purple
    // The seam is placed at 0° (right side of center), which is empty
    // space in the glyph, with purple on both ends so the seam is invisible.
    private static let angularStops: [Gradient.Stop] = [
        .init(color: Color(red: 0.537, green: 0.000, blue: 0.824), location: 0.000), // purple (seam)
        .init(color: Color(red: 0.310, green: 0.000, blue: 1.000), location: 0.250), // blue @ 90°
        .init(color: Color(red: 0.878, green: 0.000, blue: 0.565), location: 0.583), // pink @ 210°
        .init(color: Color(red: 0.537, green: 0.000, blue: 0.824), location: 0.917), // purple @ 330°
        .init(color: Color(red: 0.537, green: 0.000, blue: 0.824), location: 1.000), // purple (seam)
    ]

    private static let glyph: NSImage? = {
        guard let url = Bundle.module.url(forResource: "icon-glyph", withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    /// GitHub's official mark, rendered as a template image so it picks
    /// up the link's accent color. Bundled alongside the app icon glyph.
    private static let githubMark: NSImage? = {
        guard let url = Bundle.module.url(forResource: "github-mark", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let glyph = Self.glyph {
                    AngularGradient(
                        gradient: Gradient(stops: Self.angularStops),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    )
                    .mask {
                        Image(nsImage: glyph)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.70))
                }
            }
            .frame(width: 64, height: 88)
            .padding(.top, 28)

            // Title block — tighter internal spacing than the
            // VStack default so it reads as one unit.
            VStack(spacing: 2) {
                Text("Uncommitted")
                    .font(.title.weight(.semibold))
                Text("Version \(version)")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.70))
                Text(buildDateString)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.50))
            }

            Text("Helping developers with commitment issues since 2026.")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.70))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 4)

            Link(destination: URL(string: "https://github.com/thimo/uncommitted")!) {
                HStack(spacing: 6) {
                    if let mark = Self.githubMark {
                        Image(nsImage: mark)
                            .resizable()
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.up.right.square")
                    }
                    Text("github.com/thimo/uncommitted")
                }
                .font(.callout)
            }
            .pointingHandCursor()
            .padding(.top, 6)

            Button("Check for Updates…") {
                AppDelegate.shared?.updaterController.updater.checkForUpdates()
            }
            .padding(.top, 6)

            Text("Built with ❤️ in the Netherlands by Thimo Jansen. MIT License.")
                .padding(.top, 6)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.50))
                .padding(.bottom, 16)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
