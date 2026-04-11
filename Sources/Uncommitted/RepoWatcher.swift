import Foundation
import CoreServices

final class RepoWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: (URL) -> Void

    init(onChange: @escaping (URL) -> Void) {
        self.onChange = onChange
    }

    func watch(_ urls: [URL]) {
        stop()
        guard !urls.isEmpty else { return }

        let paths = urls.map(\.path) as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, _, eventPaths, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes set, eventPaths is a CFArrayRef of CFStringRef.
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            for case let path as String in (cfArray as NSArray) {
                watcher.onChange(URL(fileURLWithPath: path))
            }
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // built-in latency: coalesces rapid file bursts
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(newStream, .main)
        FSEventStreamStart(newStream)
        stream = newStream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}
