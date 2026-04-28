import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "nl.defrog.uncommitted", category: "config")

public final class ConfigStore: ObservableObject {
    @Published public var config: Config {
        didSet { scheduleSave() }
    }

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    public init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = support.appendingPathComponent("Uncommitted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(Config.self, from: data) {
            self.config = loaded
        } else {
            self.config = Config()
        }
    }

    public func addSource(path: String, scanDepth: Int = 1) {
        let expanded = (path as NSString).expandingTildeInPath
        guard !config.sources.contains(where: { $0.path == expanded }) else { return }
        config.sources.append(Source(path: expanded, scanDepth: scanDepth))
    }

    public func removeSource(id: Source.ID) {
        config.sources.removeAll { $0.id == id }
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
        do {
            let data = try encoder.encode(config)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Logged instead of silently swallowed — a failed write leaves
            // the user's edits only in memory, which is worth noticing in
            // Console.app if it ever happens (full disk, sandbox denial, …).
            log.error("Failed to save config: \(error.localizedDescription, privacy: .public)")
        }
    }
}
