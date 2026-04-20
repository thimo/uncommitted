import Foundation
import CoreServices

/// Wraps an FSEvents stream. Lives as long as the owning `RepoStore`.
/// Notes on safety: `FSEventStreamContext.info` is stored as a retained
/// `Unmanaged<RepoWatcher>`, not an unretained raw pointer. When the
/// stream is invalidated we balance that retain in a matching release
/// callback, so in-flight callbacks can't race a `stop()` and deref a
/// dangling pointer.
public final class RepoWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: (URL) -> Void

    public init(onChange: @escaping (URL) -> Void) {
        self.onChange = onChange
    }

    public func watch(_ urls: [URL]) {
        stop()
        guard !urls.isEmpty else { return }

        let paths = urls.map(\.path) as CFArray

        // Retain self into the context. The `release` callback below
        // balances this when FSEvents tears the stream down.
        let retained = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: retained,
            retain: { ptr in
                guard let ptr else { return nil }
                _ = Unmanaged<RepoWatcher>.fromOpaque(ptr).retain()
                return ptr
            },
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<RepoWatcher>.fromOpaque(ptr).release()
            },
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

        // kFSEventStreamCreateFlagFileEvents is intentionally omitted —
        // we only need to know WHICH REPO changed, not which file. Directory-
        // level events are far fewer (one per changed directory per latency
        // window vs. one per file write). kFSEventStreamCreateFlagNoDefer
        // fires the first event immediately for responsiveness; subsequent
        // events coalesce over the 2s latency window.
        let flags = UInt32(
            kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0, // kernel-level coalescing; per-repo debounce in RepoStore adds another 1s
            flags
        ) else {
            // FSEventStreamCreate keeps the retain on failure only if it
            // succeeded — if we get nil here we own the retain ourselves
            // and must release it, otherwise we leak self.
            Unmanaged<RepoWatcher>.fromOpaque(retained).release()
            return
        }

        FSEventStreamSetDispatchQueue(newStream, .main)
        FSEventStreamStart(newStream)
        stream = newStream
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}
