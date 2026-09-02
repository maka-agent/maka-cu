import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §12 vector 51 — the half of the observation budget no unit test can reach.
/// The unit half drives an injected clock, which proves the walk stops when it
/// is told to; only a real window proves the ceiling was set to a number that
/// keeps `observe` inside the host's request deadline.
///
///     OPEN_COMPUTER_USE_RUN_OBSERVE_LIVE_TEST=1 \
///         swift test --filter HostObserveLiveTests
///
/// It reads a **file dialog**, deliberately. An open or save panel is drawn by
/// `com.apple.appkit.xpc.openAndSavePanelService`, so every node of it crosses
/// an XPC boundary: measured on macOS 26.5, an ordinary window reads at
/// 0.8–7.5 ms per element while that panel reads at 23.6 ms and rising, and
/// 1500 of its elements took 35 s. Nothing about it is exotic — it is the window
/// the model is looking at whenever it does file work — and it is the window
/// that took the executor past the host's 20 s deadline and got the process
/// killed.
///
/// Preview with no open document puts one on screen by itself, which is why it
/// is the target and why it is launched rather than driven.
///
/// Every wait here is a semaphore. `wait(for:)` and `RunLoop.run` both spin the
/// main run loop; the executor's main thread sits in `readLine` and spins
/// nothing, so a live test that leans on a run loop is measuring a process that
/// does not exist.
final class HostObserveLiveTests: XCTestCase {
    func testObservingAFileDialogAnswersInsideTheCeilingAndDeclaresWhatItCut() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_LIVE_TEST=1 to run the live observation budget test")
        }

        // `AXIsProcessTrusted` asks; the prompting variant would block the run
        // on a dialog nobody is there to answer.
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not granted to the process running these tests")
        }

        let app = try backgroundLaunchedPreview()
        let windows = try windowsOf(pid: app.pid)
        XCTAssertFalse(windows.isEmpty, "Preview came up with no window to observe")

        let limits = HostLimits()
        let imageDirectory = try makeImageDirectory()
        defer { try? FileManager.default.removeItem(at: imageDirectory) }

        let inbox = ResponseInbox()
        let server = HostProtocolServer(
            output: HostOutputWriter { inbox.append($0) },
            environment: HostLiveEnvironment()
        )

        server.handle(line: #"""
        {"jsonrpc":"2.0","id":1,"method":"host.hello","params":{"protocol":"\#(makaCuProtocolVersion)","hostPid":\#(ProcessInfo.processInfo.processIdentifier),"imageDir":"\#(imageDirectory.path)","allowGlobalPointer":false}}
        """#)
        _ = try inbox.next()
        server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        _ = try inbox.next()

        var observed = 0
        for (offset, window) in windows.enumerated() {
            // No image: the ceiling under test is the tree walk's, and a capture
            // has a ceiling of its own that would be mixed into the measurement.
            let started = Date()
            server.handle(line: #"""
            {"jsonrpc":"2.0","id":\#(10 + offset),"method":"observe","params":{"session":"s1","target":{"kind":"window","appId":"\#(window.appId)","pid":\#(window.pid),"processGeneration":"\#(hostProcessGeneration(hostProcessStartTime(pid: window.pid) ?? 0))","windowId":\#(window.windowId)},"includeImage":false}}
            """#)

            // The wait is longer than the host's own deadline on purpose: an
            // executor without a ceiling must be allowed to finish, so the
            // failure it produces is "35 s" rather than "the test gave up".
            let response = try inbox.next(timeout: 120)
            let elapsed = Date().timeIntervalSince(started)

            XCTAssertNil(response["error"], "\(window.title ?? "untitled") is a window on this screen")
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            guard result["ok"] as? Bool == true else {
                // A window can close under the test, and `window_gone` is not a
                // budget failure. It is printed so a run where nothing could be
                // observed is visible rather than silently green.
                print("observe live test: \(window.title ?? "untitled") → \((result["error"] as? [String: Any])?["code"] ?? "?")")
                continue
            }

            let snapshot = try XCTUnwrap(result["snapshot"] as? [String: Any])
            let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])
            let truncated = try XCTUnwrap(snapshot["truncated"] as? [String: Any])
            let cutElements = truncated["elements"] as? Bool == true
            observed += 1

            print(String(
                format: "observe live test: %@ — %d elements in %.2fs, truncated.elements=%@",
                window.title ?? "untitled",
                elements.count,
                elapsed,
                cutElements ? "true" : "false"
            ))

            // The ceiling, plus what a scheduler on a loaded machine can add
            // between the deadline passing and the walk noticing it. Without a
            // ceiling at all this is where a file dialog lands at 35 s — and the
            // host, which waits 20 s, has by then cancelled the request and torn
            // the executor down.
            XCTAssertLessThan(
                elapsed,
                Double(limits.treeWalkCeilingMs) / 1000 + 3,
                "an observation that outlives its ceiling outlives the host's deadline too"
            )

            // A snapshot is only usable if it has tokens, however short it is.
            XCTAssertFalse(elements.isEmpty, "a snapshot with no elements cannot be dispatched against")
            XCTAssertNotNil(elements.first?["token"] as? String)

            // And a walk that spent most of its budget did not come back
            // claiming it had seen the whole window.
            if elapsed > Double(limits.treeWalkCeilingMs) / 1000 * 0.9 {
                XCTAssertTrue(
                    cutElements,
                    "a walk stopped by the clock must say the tree is short (§5.2)"
                )
            }
        }

        XCTAssertGreaterThan(observed, 0, "nothing was observed, so nothing was proved")

        server.handle(line: #"{"jsonrpc":"2.0","id":99,"method":"session.end","params":{"session":"s1"}}"#)
        _ = try inbox.next()
    }

    // MARK: - Helpers

    /// Preview, running, without having taken the foreground to get there. It is
    /// left running: this test does not own it, and quitting an application a
    /// user may have opened is a side effect a test has no business having.
    private func backgroundLaunchedPreview() throws -> RunningAppDescriptor {
        guard FileManager.default.fileExists(atPath: "/System/Applications/Preview.app") else {
            throw XCTSkip("Preview is not installed")
        }

        let resolved = Outcome()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            resolved.result = Result { try AppDiscovery.resolve("Preview", waitFor: 20) }
            finished.signal()
        }

        guard finished.wait(timeout: .now() + 40) == .success else {
            throw ComputerUseError.message("Preview never resolved")
        }
        return try XCTUnwrap(resolved.result).get()
    }

    /// Its on-screen ordinary windows, waited for: a launch returns before the
    /// window is mapped, measured at 1.3–3.2 s against 2.3–4.5 s (§5.7).
    private func windowsOf(pid: pid_t) throws -> [HostWindowInfo] {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let windows = HostWindowInventory.onScreenWindows()
                .filter { $0.pid == pid && $0.layer == 0 && $0.bounds.width > 64 && $0.bounds.height > 64 }
            if !windows.isEmpty {
                return windows
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        return []
    }

    private func makeImageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-observe-live-\(UUID().uuidString)", isDirectory: true)
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
