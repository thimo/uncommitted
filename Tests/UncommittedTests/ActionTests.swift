import Foundation
import UncommittedCore

enum ActionTests {
    static func register() {
        // MARK: - {path} expansion

        test("Action/expand_substitutesPath") {
            let out = ActionRunner.expand(command: "gittower {path}", repoPath: "/Users/alice/src/app")
            try expectEqual(out, "gittower /Users/alice/src/app")
        }

        test("Action/expand_replacesEveryOccurrence") {
            let out = ActionRunner.expand(command: "cd {path} && code {path}", repoPath: "/r")
            try expectEqual(out, "cd /r && code /r")
        }

        test("Action/expand_noTokenIsLeftUnchanged") {
            let out = ActionRunner.expand(command: "git status", repoPath: "/r")
            try expectEqual(out, "git status")
        }

        test("Action/expand_pathWithSpacesIsInsertedVerbatim") {
            // Expansion does not quote — the path is substituted as-is and the
            // shell command is responsible for any quoting around {path}.
            let out = ActionRunner.expand(command: "open '{path}'", repoPath: "/Users/alice/My Repos/app")
            try expectEqual(out, "open '/Users/alice/My Repos/app'")
        }

        test("Action/expand_emptyCommandStaysEmpty") {
            try expectEqual(ActionRunner.expand(command: "", repoPath: "/r"), "")
        }

        // MARK: - Codable round-trips

        test("Action/kind_finder_roundTrips") {
            try roundTripKind(.finder)
        }

        test("Action/kind_app_roundTrips") {
            try roundTripKind(.app("Ghostty"))
        }

        test("Action/kind_command_roundTrips") {
            try roundTripKind(.command("open -a Terminal {path}"))
        }

        test("Action/roundTrips_withAllOptionalFields") {
            let original = Action(
                name: "Tower",
                kind: .command("gittower {path}"),
                iconApp: "Tower",
                role: .gitClient
            )
            let decoded = try roundTrip(original)
            try expectEqual(decoded, original)
            try expectEqual(decoded.iconApp, "Tower")
            try expectEqual(decoded.role, .gitClient)
        }

        test("Action/roundTrips_withoutOptionalFields") {
            let original = Action(name: "Finder", kind: .finder)
            let decoded = try roundTrip(original)
            try expectEqual(decoded, original)
            try expectNil(decoded.iconApp)
            try expectNil(decoded.role)
        }

        test("Action/optionalFields_areOmittedWhenNil") {
            // encodeIfPresent must keep iconApp/role out of the JSON so older
            // builds that don't know the keys still decode cleanly.
            let data = try JSONEncoder().encode(Action(name: "Finder", kind: .finder))
            let json = String(data: data, encoding: .utf8) ?? ""
            try expect(!json.contains("iconApp"), "iconApp should be omitted when nil")
            try expect(!json.contains("role"), "role should be omitted when nil")
        }

        test("Action/decodesLegacy_withoutIconAppAndRole") {
            // A config written before iconApp/role existed must still decode.
            let json = """
            { "id": "00000000-0000-0000-0000-000000000001",
              "name": "Finder",
              "kind": { "finder": {} } }
            """.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(Action.self, from: json)
            try expectEqual(decoded.name, "Finder")
            try expectEqual(decoded.kind, .finder)
            try expectNil(decoded.iconApp)
            try expectNil(decoded.role)
        }

        test("ActionRole/rawValueIsStable") {
            // The raw value lands in config.json on disk — changing it would
            // orphan every existing user's preferred-git-client setting.
            try expectEqual(ActionRole.gitClient.rawValue, "gitClient")
        }

        // MARK: - AppLocator

        test("AppLocator/unknownAppReturnsNil") {
            try expectNil(AppLocator.url(forApp: "ThisAppDoesNotExist-9f3a2b"))
        }
    }

    // MARK: - Helpers

    private static func roundTrip(_ action: Action) throws -> Action {
        let data = try JSONEncoder().encode(action)
        return try JSONDecoder().decode(Action.self, from: data)
    }

    private static func roundTripKind(_ kind: ActionKind) throws {
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(ActionKind.self, from: data)
        try expectEqual(decoded, kind)
    }
}
