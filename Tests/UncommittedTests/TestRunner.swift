import Foundation

// A tiny test runner for the Uncommitted package. Swift's Testing framework
// and XCTest are both unavailable on a Command Line Tools-only toolchain, so
// this file defines a stripped-down runner that works everywhere. Keep it
// small — if it grows, swap in swift-testing once Xcode is installed.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt

    var description: String { "\(file):\(line) — \(message)" }
}

enum TestRegistry {
    nonisolated(unsafe) static var tests: [(String, () throws -> Void)] = []
}

func test(_ name: String, _ body: @escaping () throws -> Void) {
    TestRegistry.tests.append((name, body))
}

func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "expectation failed",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if !condition() {
        throw TestFailure(message: message(), file: file, line: line)
    }
}

func expectEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    file: StaticString = #file,
    line: UInt = #line
) throws {
    let a = actual()
    let e = expected()
    if a != e {
        throw TestFailure(message: "expected \(e), got \(a)", file: file, line: line)
    }
}

func expectNil<T>(
    _ value: @autoclosure () -> T?,
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if let v = value() {
        throw TestFailure(message: "expected nil, got \(v)", file: file, line: line)
    }
}

func requireNotNil<T>(
    _ value: @autoclosure () -> T?,
    file: StaticString = #file,
    line: UInt = #line
) throws -> T {
    guard let v = value() else {
        throw TestFailure(message: "expected non-nil", file: file, line: line)
    }
    return v
}

// MARK: - Entry point

@main
struct TestRunnerMain {
    static func main() {
        GitStatusParserTests.register()
        ConfigCodableTests.register()
        RepoResolutionTests.register()
        FetchSchedulerTests.register()
        FetchStateStoreTests.register()
        GitErrorClassifierTests.register()

        var passed = 0
        var failed = 0

        for (name, body) in TestRegistry.tests {
            do {
                try body()
                print("  ✓ \(name)")
                passed += 1
            } catch let failure as TestFailure {
                print("  ✗ \(name)")
                print("      \(failure.description)")
                failed += 1
            } catch {
                print("  ✗ \(name)")
                print("      unexpected error: \(error)")
                failed += 1
            }
        }

        let total = passed + failed
        print("")
        if failed == 0 {
            print("\(total) passed")
        } else {
            print("\(failed) of \(total) failed")
            exit(1)
        }
    }
}
