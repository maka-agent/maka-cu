import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §12 vector 55 — the half of settling no unit test can reach. The unit half
/// drives an injected clock, which proves the loop stops when it is told to;
/// only real windows prove what a look at one costs, and the whole defect this
/// vector exists for is a budget set against a cost nobody had measured.
///
///     OPEN_COMPUTER_USE_RUN_SETTLE_LIVE_TEST=1 \
///         swift test --filter HostSettleLiveTests
///
/// It settles rather than dispatches. Settling is a read — one
/// `hostRecomputeWindowDigest` per round, which is the same call the dispatch
/// path makes — so this vector can be pointed at the user's own windows without
/// pressing anything in them.
///
/// System Settings is launched, in the background, because it is the window the
/// numbers came from: it hosts its panes in another process, so every element of
/// its digest crosses XPC and one look at it costs more than half the budget. It
/// is left running afterwards, as vector 51 leaves Preview running — this test
/// does not own the user's applications.
///
/// Every wait here is a semaphore. `wait(for:)` and `RunLoop.run` both spin the
/// main run loop; the executor's main thread sits in `readLine` and spins
/// nothing, so a live test that leans on a run loop is measuring a process that
/// does not exist.
final class HostSettleLiveTests: XCTestCase {
    func testSettlingReportsTheTimeItReallySpentOnEveryWindowOnThisScreen() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_SETTLE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_SETTLE_LIVE_TEST=1 to run the live settle test")
        }

        // `AXIsProcessTrusted` asks; the prompting variant would block the run
        // on a dialog nobody is there to answer.
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not granted to the process running these tests")
        }

        let limits = HostLimits()
        let environment = HostLiveEnvironment()
        let heavy = try backgroundLaunchedSystemSettings()
        let windows = try settleTargets(preferring: heavy)
        XCTAssertFalse(windows.isEmpty, "there is nothing on this screen to settle")

        let imageDirectory = try makeImageDirectory()
        defer { try? FileManager.default.removeItem(at: imageDirectory) }

        let inbox = ResponseInbox()
        let server = HostProtocolServer(
            output: HostOutputWriter { inbox.append($0) },
            environment: environment
        )

        server.handle(line: #"""
        {"jsonrpc":"2.0","id":1,"method":"host.hello","params":{"protocol":"\#(makaCuProtocolVersion)","hostPid":\#(ProcessInfo.processInfo.processIdentifier),"imageDir":"\#(imageDirectory.path)","allowGlobalPointer":false}}
        """#)
        _ = try inbox.next()
        server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        _ = try inbox.next()

        var settled = 0
        for window in windows {
            // No image: the cost under test is the digest recomputation, and a
            // capture has a ceiling of its own that would be mixed into it.
            guard case .success(let snapshot) = server.buildSnapshot(
                session: "s1",
                target: .window(
                    appId: window.appId,
                    pid: window.pid,
                    processGeneration: hostProcessGeneration(
                        hostProcessStartTime(pid: window.pid) ?? 0
                    ),
                    windowId: window.windowId
                ),
                includeImage: false,
                menuScope: nil,
                maxElements: limits.maxElements,
                maxDepth: limits.maxDepth,
                maxTextChars: limits.maxTextChars
            ) else {
                // A window can close under the test, and that is not a budget
                // failure. Printed so a run that measured nothing is visible
                // rather than silently green.
                print("settle live test: \(window.title ?? "untitled") could not be observed")
                continue
            }

            let probe = environment.bindingProbe(windowId: window.windowId, windowBounds: window.bounds)
            var looks = 0
            var costliestLook: TimeInterval = 0

            let started = Date()
            let result = hostSettle(
                ceilingMs: limits.settleCeilingMs,
                pollMs: hostSettlePollMs,
                sample: {
                    let lookStarted = Date()
                    let digest = hostRecomputeWindowDigest(snapshot: snapshot, window: window, probe: probe)
                    looks += 1
                    costliestLook = max(costliestLook, Date().timeIntervalSince(lookStarted))
                    return digest
                }
            )
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            settled += 1

            print(String(
                format: "settle live test: %@ (%@) — %d elements, %d looks at up to %.0f ms, waitedMs=%d in %d ms, reason=%@",
                window.appName,
                window.title ?? "untitled",
                snapshot.payload.elements.count,
                looks,
                costliestLook * 1000,
                result.report.waitedMs,
                elapsedMs,
                result.report.reason.rawValue
            ))

            // The vector. `waitedMs` is the field the host traces to see
            // overruns, and the executor that shipped answered it with
            // `limits.settleCeilingMs` — a constant that agrees with the clock
            // only by accident, and never on the window that overran.
            XCTAssertLessThanOrEqual(
                abs(result.report.waitedMs - elapsedMs),
                150,
                "\(window.appName): waitedMs \(result.report.waitedMs) is not the \(elapsedMs) ms this settle spent"
            )

            // The overrun is bounded by the one look that cannot be estimated
            // before it is paid for. The old loop's bound was two.
            XCTAssertLessThanOrEqual(
                Double(result.report.waitedMs),
                Double(limits.settleCeilingMs) + costliestLook * 1000 + 250,
                "\(window.appName): a settle may overrun by one look, not by two"
            )

            switch result.report.reason {
            case .quiesced:
                XCTAssertTrue(result.report.quiesced)
                XCTAssertGreaterThanOrEqual(
                    looks,
                    2,
                    "\(window.appName): quiescence is two looks that agree, so one look cannot prove it"
                )
            case .windowTooSlow:
                XCTAssertFalse(result.report.quiesced)
                XCTAssertEqual(
                    looks,
                    1,
                    "\(window.appName): `window_too_slow` is the answer when a second look was never affordable"
                )
            case .ceiling:
                XCTAssertFalse(result.report.quiesced)
                XCTAssertGreaterThanOrEqual(
                    looks,
                    2,
                    "\(window.appName): `ceiling` claims the window was compared and had moved"
                )
            case .notRequested:
                XCTFail("\(window.appName): settling was requested")
            }

            XCTAssertFalse(result.digest.isEmpty, "§6.5 judges the dispatch by this digest")
        }

        XCTAssertGreaterThan(settled, 0, "nothing was settled, so nothing was proved")

        server.handle(line: #"{"jsonrpc":"2.0","id":99,"method":"session.end","params":{"session":"s1"}}"#)
        _ = try inbox.next()
    }

    // MARK: - Helpers

    /// System Settings, running, without having taken the foreground to get
    /// there, and left running afterwards.
    private func backgroundLaunchedSystemSettings() throws -> pid_t? {
        guard FileManager.default.fileExists(atPath: "/System/Applications/System Settings.app") else {
            return nil
        }

        let resolved = Outcome()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            resolved.result = Result { try AppDiscovery.resolve("System Settings", waitFor: 20) }
            finished.signal()
        }

        guard finished.wait(timeout: .now() + 40) == .success else {
            return nil
        }
        return try? resolved.result?.get().pid
    }

    /// Ordinary on-screen windows, the heavy one first, waited for: a launch
    /// returns before its window is mapped (§5.7). Bounded, because every entry
    /// costs a tree walk before it costs a settle.
    private func settleTargets(preferring pid: pid_t?) throws -> [HostWindowInfo] {
        let deadline = Date().addingTimeInterval(15)
        var candidates: [HostWindowInfo] = []

        while Date() < deadline {
            candidates = HostWindowInventory.onScreenWindows()
                .filter { $0.layer == 0 && $0.bounds.width > 64 && $0.bounds.height > 64 }
            if pid == nil || candidates.contains(where: { $0.pid == pid }) {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        let heavy = candidates.filter { $0.pid == pid }
        let rest = candidates.filter { $0.pid != pid }
        return Array((heavy + rest).prefix(6))
    }

    private func makeImageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-settle-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private final class Outcome: @unchecked Sendable {
        var result: Result<RunningAppDescriptor, Error>?
    }

    /// Line-delimited responses collected off whichever lane produced them, and
    /// handed to the main thread through a semaphore rather than a run loop.
    private final class ResponseInbox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        private let arrived = DispatchSemaphore(value: 0)

        func append(_ data: Data) {
            lock.lock()
            lines.append(data)
            lock.unlock()
            arrived.signal()
        }

        func next(timeout: TimeInterval = 5) throws -> [String: Any] {
            guard arrived.wait(timeout: .now() + timeout) == .success else {
                throw ComputerUseError.message("no response within \(timeout)s")
            }

            lock.lock()
            let data = lines.removeFirst()
            lock.unlock()
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }
}
