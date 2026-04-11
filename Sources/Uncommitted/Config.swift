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

struct Config: Codable, Equatable {
    var sources: [Source]
    var actions: [Action]
    var hideCleanRepos: Bool

    init(
        sources: [Source] = [],
        actions: [Action] = Self.defaultActions,
        hideCleanRepos: Bool = false
    ) {
        self.sources = sources
        self.actions = actions
        self.hideCleanRepos = hideCleanRepos
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sources = try container.decodeIfPresent([Source].self, forKey: .sources) ?? []
        self.actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? Self.defaultActions
        self.hideCleanRepos = try container.decodeIfPresent(Bool.self, forKey: .hideCleanRepos) ?? false
    }
}
