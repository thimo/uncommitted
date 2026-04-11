import Foundation

struct Source: Codable, Identifiable, Hashable {
    var path: String
    var scanDepth: Int

    var id: String { path }

    init(path: String, scanDepth: Int = 1) {
        self.path = path
        self.scanDepth = scanDepth
    }

    enum CodingKeys: String, CodingKey {
        case path
        case scanDepth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.scanDepth = try container.decodeIfPresent(Int.self, forKey: .scanDepth) ?? 1
    }
}

enum MenuBarLabelStyle: String, Codable, CaseIterable, Hashable {
    /// Uncommitted files + unpushed commits, summed into one number.
    case total
    /// Number of repositories that have any work pending.
    case dirtyRepos
    /// Two groups: `N` for uncommitted files, `↑M` for unpushed commits.
    case split
    /// Branch icon only — no number in the menu bar.
    case iconOnly

    var displayName: String {
        switch self {
        case .total:      return "Total files and commits"
        case .dirtyRepos: return "Repositories needing attention"
        case .split:      return "Files and commits, split"
        case .iconOnly:   return "Icon only"
        }
    }
}

struct Config: Codable, Equatable {
    var sources: [Source]
    var actions: [Action]
    var hideCleanRepos: Bool
    var menuBarLabelStyle: MenuBarLabelStyle

    init(
        sources: [Source] = [],
        actions: [Action] = Self.defaultActions,
        hideCleanRepos: Bool = false,
        menuBarLabelStyle: MenuBarLabelStyle = .total
    ) {
        self.sources = sources
        self.actions = actions
        self.hideCleanRepos = hideCleanRepos
        self.menuBarLabelStyle = menuBarLabelStyle
    }

    static var defaultActions: [Action] {
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sources = try container.decodeIfPresent([Source].self, forKey: .sources) ?? []
        self.actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? Self.defaultActions
        self.hideCleanRepos = try container.decodeIfPresent(Bool.self, forKey: .hideCleanRepos) ?? false
        self.menuBarLabelStyle = try container.decodeIfPresent(MenuBarLabelStyle.self, forKey: .menuBarLabelStyle) ?? .total
    }
}
