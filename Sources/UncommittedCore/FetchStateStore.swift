import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "nl.thimo.uncommitted", category: "fetch-state")

/// Persists per-repo fetch bookkeeping to
/// `~/Library/Application Support/Uncommitted/fetch-state.json`.
/// Keyed on the repo's standardized URL path so entries survive across
/// launches even though `Repo.id` (UUID) is regenerated each time.
public final class FetchStateStore: ObservableObject {
    /// Map from `URL.standardizedFileURL.path` to `FetchState`.
    @Published public private(set) var states: [String: FetchState] = [:]

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    /// Custom initializer used by tests to redirect persistence away
    /// from the user's real Application Support directory. Production
    /// code uses the parameter-less `init()` below.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([String: FetchState].self, from: data) {
            self.states = loaded
        }
    }

    public convenience init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = support.appendingPathComponent("Uncommitted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("fetch-state.json"))
    }

    public func state(for url: URL) -> FetchState {
        states[Self.key(for: url)] ?? .initial
    }

    /// Mutate the state for `url` via a closure. Persists asynchronously.
    /// Must be called on the main thread — the underlying `@Published`
    /// dict is not safe to mutate concurrently with SwiftUI reads.
    public func update(_ url: URL, _ transform: (inout FetchState) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = Self.key(for: url)
        var current = states[key] ?? .initial
        transform(&current)
        states[key] = current
        scheduleSave()
    }

    /// Drop entries for repos that no longer exist (e.g. removed sources)
    /// so the file doesn't grow unboundedly. Main thread only.
    public func prune(to keepURLs: [URL]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let keepKeys = Set(keepURLs.map { Self.key(for: $0) })
        let before = states.count
        states = states.filter { keepKeys.contains($0.key) }
        if states.count != before {
            scheduleSave()
        }
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(states)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to save fetch state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
