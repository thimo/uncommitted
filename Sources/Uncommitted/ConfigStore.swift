import Foundation
import Combine

final class ConfigStore: ObservableObject {
    @Published var config: Config {
        didSet { scheduleSave() }
    }

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    init() {
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

    func addSource(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard !config.sources.contains(where: { $0.path == expanded }) else { return }
        config.sources.append(Source(path: expanded))
    }

    func removeSource(id: Source.ID) {
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
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
