import Foundation
import UncommittedCore

enum FetchStateStoreTests {
    static func register() {
        // MARK: - prune

        test("FetchStateStore/prune_removesOrphanEntries") {
            let store = makeTempStore()
            let kept = URL(fileURLWithPath: "/tmp/uncommitted-test/keep")
            let orphan = URL(fileURLWithPath: "/tmp/uncommitted-test/orphan")
            store.update(kept) { $0.consecutiveFailures = 1 }
            store.update(orphan) { $0.consecutiveFailures = 2 }

            store.prune(to: [kept])

            // The kept entry stays, the orphan goes.
            try expectEqual(store.state(for: kept).consecutiveFailures, 1)
            try expectEqual(store.state(for: orphan).consecutiveFailures, 0)
        }

        test("FetchStateStore/prune_emptyKeepList_dropsEverything") {
            let store = makeTempStore()
            let url = URL(fileURLWithPath: "/tmp/uncommitted-test/anything")
            store.update(url) { $0.noRemote = true }

            store.prune(to: [])

            try expectEqual(store.state(for: url), FetchState.initial)
        }

        // MARK: - state(for:) initial fallback

        test("FetchStateStore/state_unknownURL_returnsInitial") {
            let store = makeTempStore()
            let url = URL(fileURLWithPath: "/tmp/uncommitted-test/never-seen")
            try expectEqual(store.state(for: url), FetchState.initial)
        }

        test("FetchStateStore/update_preservesOtherFieldsAcrossMutations") {
            let store = makeTempStore()
            let url = URL(fileURLWithPath: "/tmp/uncommitted-test/repo")
            store.update(url) { $0.consecutiveFailures = 5 }
            store.update(url) { $0.lastAttemptWasManual = true }

            let s = store.state(for: url)
            try expectEqual(s.consecutiveFailures, 5)
            try expect(s.lastAttemptWasManual)
        }

        // MARK: - FetchState codec

        test("FetchState/initial_roundTrips") {
            let original = FetchState.initial
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(FetchState.self, from: data)
            try expectEqual(decoded, original)
        }

        test("FetchState/allFieldsPopulated_roundTrips") {
            let original = FetchState(
                lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastSuccessAt: Date(timeIntervalSince1970: 1_700_000_500),
                consecutiveFailures: 4,
                lastAttemptWasManual: true,
                noRemote: false
            )

            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(FetchState.self, from: data)
            try expectEqual(decoded, original)
        }
    }

    /// Creates a FetchStateStore writing to a unique tmp file so tests
    /// don't touch the user's real fetch-state.json.
    private static func makeTempStore() -> FetchStateStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncommitted-fetch-state-\(UUID().uuidString).json")
        // Make sure no leftover from a prior run is loaded.
        try? FileManager.default.removeItem(at: url)
        return FetchStateStore(fileURL: url)
    }
}
