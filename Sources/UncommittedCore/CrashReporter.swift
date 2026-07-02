import Foundation
import Darwin

/// Last-breath logging so an unexplained disappearance leaves a trace in
/// the diagnostics log. Born from a real incident: the menu-bar icon
/// vanished once with a clean exit(0) and zero forensics — no crash
/// report, no log line, nothing to diagnose. Three layers:
///
/// 1. `atexit` — catches every `exit()` path, including a "clean" exit(0)
///    nothing else would record.
/// 2. `NSSetUncaughtExceptionHandler` — ObjC exceptions, with the full
///    call stack (Foundation is still safe to use here).
/// 3. Signal handlers — SIGSEGV & friends, plus SIGTERM (what `killall`
///    sends). Restricted to async-signal-safe calls: `write(2)` of
///    static strings and `backtrace_symbols_fd` into a pre-opened
///    O_APPEND descriptor, then re-raise with the default handler so
///    macOS still produces its regular crash report.
public enum CrashReporter {
    nonisolated(unsafe) private static var crashFD: Int32 = -1
    /// Pre-allocated at install time — malloc inside a signal handler is
    /// not async-signal-safe.
    nonisolated(unsafe) private static var backtraceBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

    private static let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP]

    public static func install(log: DiagnosticsLog = .shared) {
        crashFD = log.openRawAppendDescriptor()
        backtraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)

        atexit {
            DiagnosticsLog.shared.info("app", "process exiting via exit()")
        }

        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            DiagnosticsLog.shared.error(
                "crash",
                "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "(no reason)")\n\(stack)"
            )
        }

        for sig in fatalSignals {
            signal(sig, fatalSignalHandler)
        }
        signal(SIGTERM, terminationSignalHandler)
    }

    private static let fatalSignalHandler: @convention(c) (Int32) -> Void = { sig in
        if CrashReporter.crashFD >= 0 {
            CrashReporter.writeRaw("\n=== Uncommitted crashed: ")
            CrashReporter.writeSignalName(sig)
            CrashReporter.writeRaw(" ===\n")
            if let buffer = CrashReporter.backtraceBuffer {
                let count = backtrace(buffer, 128)
                backtrace_symbols_fd(buffer, count, CrashReporter.crashFD)
            }
            fsync(CrashReporter.crashFD)
        }
        // Restore the default handler and re-raise so the OS crash
        // reporter still runs and the exit status stays truthful.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static let terminationSignalHandler: @convention(c) (Int32) -> Void = { sig in
        if CrashReporter.crashFD >= 0 {
            CrashReporter.writeRaw("\n=== Uncommitted received SIGTERM — killed externally (killall, logout, …) ===\n")
            fsync(CrashReporter.crashFD)
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static func writeRaw(_ s: StaticString) {
        s.withUTF8Buffer { buf in
            _ = write(crashFD, buf.baseAddress, buf.count)
        }
    }

    private static func writeSignalName(_ sig: Int32) {
        switch sig {
        case SIGSEGV: writeRaw("SIGSEGV")
        case SIGBUS: writeRaw("SIGBUS")
        case SIGILL: writeRaw("SIGILL")
        case SIGFPE: writeRaw("SIGFPE")
        case SIGABRT: writeRaw("SIGABRT")
        case SIGTRAP: writeRaw("SIGTRAP")
        default: writeRaw("signal ?")
        }
    }
}
