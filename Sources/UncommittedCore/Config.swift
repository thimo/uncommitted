import Foundation

public struct Source: Codable, Identifiable, Hashable {
    public var path: String
    public var scanDepth: Int

    public var id: String { path }

    public init(path: String, scanDepth: Int = 1) {
        self.path = path
        self.scanDepth = scanDepth
    }

    enum CodingKeys: String, CodingKey {
        case path
        case scanDepth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.scanDepth = try container.decodeIfPresent(Int.self, forKey: .scanDepth) ?? 1
    }
}

public enum MenuBarLabelStyle: String, Codable, CaseIterable, Hashable {
    /// Uncommitted files + unpushed commits, summed into one number.
    case total
    /// Number of repositories that have any work pending.
    case dirtyRepos
    /// Two groups: `N` for uncommitted files, `↑M` for unpushed commits.
    case split
    /// Branch icon only — no number in the menu bar.
    case iconOnly

    public var displayName: String {
        switch self {
        case .total:      return "Total files and commits"
        case .dirtyRepos: return "Repositories with changes"
        case .split:      return "Files and commits, separately"
        case .iconOnly:   return "None"
        }
    }
}

public struct Config: Codable, Equatable {
    public var sources: [Source]
    public var actions: [Action]
    public var hideCleanRepos: Bool
    public var menuBarLabelStyle: MenuBarLabelStyle
    /// When true, the FetchScheduler runs `git fetch` on tracked repos
    /// at a tiered cadence (daily for active, weekly for idle). See
    /// docs/auto-fetch.md.
    public var fetchFromRemotes: Bool
    /// Global hotkey to open/close the popup. Nil means no hotkey registered.
    public var globalShortcut: GlobalShortcut?

    public init(
        sources: [Source] = [],
        actions: [Action] = Self.defaultActions,
        hideCleanRepos: Bool = false,
        menuBarLabelStyle: MenuBarLabelStyle = .total,
        fetchFromRemotes: Bool = false,
        globalShortcut: GlobalShortcut? = .defaultShortcut
    ) {
        self.sources = sources
        self.actions = actions
        self.hideCleanRepos = hideCleanRepos
        self.menuBarLabelStyle = menuBarLabelStyle
        self.fetchFromRemotes = fetchFromRemotes
        self.globalShortcut = globalShortcut
    }

    public static var defaultActions: [Action] {
        [
            Action(name: "Finder", kind: .finder),
            Action(name: "Visual Studio Code", kind: .app("Visual Studio Code")),
            Action(name: "Terminal", kind: .app("Terminal")),
        ]
    }

    enum CodingKeys: String, CodingKey {
        case sources
        case actions
        case hideCleanRepos
        case menuBarLabelStyle
        case fetchFromRemotes
        case globalShortcut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sources = try container.decodeIfPresent([Source].self, forKey: .sources) ?? []
        self.actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? Self.defaultActions
        self.hideCleanRepos = try container.decodeIfPresent(Bool.self, forKey: .hideCleanRepos) ?? false
        self.menuBarLabelStyle = try container.decodeIfPresent(MenuBarLabelStyle.self, forKey: .menuBarLabelStyle) ?? .total
        self.fetchFromRemotes = try container.decodeIfPresent(Bool.self, forKey: .fetchFromRemotes) ?? false
        // Absent key → default shortcut (new installs). Explicit null → no shortcut (user cleared it).
        if container.contains(.globalShortcut) {
            self.globalShortcut = try container.decodeIfPresent(GlobalShortcut.self, forKey: .globalShortcut)
        } else {
            self.globalShortcut = .defaultShortcut
        }
    }
}
