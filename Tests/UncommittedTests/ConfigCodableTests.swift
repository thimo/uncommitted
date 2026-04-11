import Foundation
import UncommittedCore

enum ConfigCodableTests {
    static func register() {
        test("Config/defaultConfig_roundTrips") {
            let original = Config()
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(Config.self, from: data)

            try expectEqual(decoded.sources, original.sources)
            try expectEqual(decoded.hideCleanRepos, original.hideCleanRepos)
            try expectEqual(decoded.menuBarLabelStyle, original.menuBarLabelStyle)
            try expectEqual(decoded.actions.count, original.actions.count)
        }

        test("Config/nonDefaultFields_roundTrip") {
            let sources = [
                Source(path: "/Users/alice/src", scanDepth: 2),
                Source(path: "/Users/alice/work", scanDepth: 0),
            ]
            let actions = [
                Action(name: "Ghostty", kind: .app("Ghostty")),
                Action(name: "Open shell", kind: .command("open -a Terminal {path}")),
            ]
            let original = Config(
                sources: sources,
                actions: actions,
                hideCleanRepos: true,
                menuBarLabelStyle: .dirtyRepos
            )

            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(Config.self, from: data)

            try expectEqual(decoded.sources, sources)
            try expectEqual(decoded.actions, actions)
            try expect(decoded.hideCleanRepos)
            try expectEqual(decoded.menuBarLabelStyle, .dirtyRepos)
        }

        test("Config/decodingEmptyObject_fallsBackToDefaults") {
            // A brand-new user or a corrupted-down-to-`{}` config should still
            // produce a usable Config without throwing.
            let json = "{}".data(using: .utf8)!
            let decoded = try JSONDecoder().decode(Config.self, from: json)

            try expectEqual(decoded.sources, [])
            try expect(decoded.hideCleanRepos == false)
            try expectEqual(decoded.menuBarLabelStyle, .total)
            try expect(decoded.actions.isEmpty == false, "should fall back to default action list")
        }

        test("Config/decodingOnlySources_keepsOtherDefaults") {
            // v0.2 config shape — had sources but no actions / hideCleanRepos /
            // menuBarLabelStyle. Must still decode without loss of existing data.
            let json = """
            {
              "sources": [
                { "path": "/Users/alice/src" }
              ]
            }
            """.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(Config.self, from: json)

            try expectEqual(decoded.sources.count, 1)
            try expectEqual(decoded.sources.first?.path, "/Users/alice/src")
            try expectEqual(decoded.sources.first?.scanDepth, 1)
            try expectEqual(decoded.menuBarLabelStyle, .total)
            try expect(decoded.actions.isEmpty == false)
        }

        test("Config/menuBarLabelStyle_rawValuesAreStable") {
            // The raw values are what lands in config.json on disk — changing
            // them silently would orphan every existing user's setting.
            try expectEqual(MenuBarLabelStyle.total.rawValue, "total")
            try expectEqual(MenuBarLabelStyle.dirtyRepos.rawValue, "dirtyRepos")
            try expectEqual(MenuBarLabelStyle.split.rawValue, "split")
            try expectEqual(MenuBarLabelStyle.iconOnly.rawValue, "iconOnly")
        }
    }
}
