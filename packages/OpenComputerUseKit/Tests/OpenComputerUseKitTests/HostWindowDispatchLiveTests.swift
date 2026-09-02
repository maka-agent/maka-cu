import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §12 vectors 56, 57 and 58 — the halves that need a real window.
///
///     OPEN_COMPUTER_USE_RUN_WINDOW_LIVE_TEST=1 \
///         swift test --filter HostWindowDispatchLiveTests
///
/// Three things here cannot be reached from a unit test, and each of them is a
/// way the executor can be green and wrong:
///
/// 1. **Whether a window moves at all.** No fake `AXUIElement` has a position,
///    so both sides of the readback come back `nil` in a unit test and the
///    executor takes its "nothing to check" arm — which is the same answer a
///    working move produces for a window that did not move.
/// 2. **Whether the window server has caught up.** The application answers
///    `AXPosition` in 3–16 ms and the window server follows 26–172 ms later, and
///    `observe` resolves its target out of the window server. An executor that
///    returns on the application's acknowledgement passes every unit vector and
///    then cannot find, in its own `observeAfter`, the window it just moved.
/// 3. **Whether anything took the foreground.** The invariant §6 rests on is
///    about the machine, and only the machine can be asked.
///
/// Every dispatch below asserts the frontmost pid across it. TextEdit and
/// Calculator are launched in the background and left running — quitting an
/// application the user may have opened is a side effect a test has no business
/// having — and every window is put back exactly where it was found.
///
/// Every wait is a semaphore. `wait(for:)` and `RunLoop.run` both spin the main
/// run loop, which thaws exactly the timings this file exists to catch: the
/// executor's main thread sits in `readLine` and spins nothing.
final class HostWindowDispatchLiveTests: XCTestCase {
    // MARK: - Vectors 57 and 58: moving and resizing

    func testMovingAndResizingAWindowLandsItAndTakesNoForeground() throws {
        try requireLiveDesktop()

        let app = try backgroundLaunched("TextEdit")
        let (window, element) = try windowAndElement(pid: app.pid)

        let originalPosition = try XCTUnwrap(HostAX.point(element, kAXPositionAttribute))
        let originalSize = try XCTUnwrap(HostAX.size(element, kAXSizeAttribute))
        defer {
            _ = HostAX.write(element, kAXSizeAttribute, size: originalSize)
            _ = HostAX.write(element, kAXPositionAttribute, point: originalPosition)
            settleWindowServer(window, element)
        }

        let session = try LiveSession()
        defer { session.end() }

        // --- move ---

        var frame = try session.observe(window)
        var front = frontmostPid()
        let target = CGPoint(x: originalPosition.x - 120, y: originalPosition.y + 60)

        var result = try session.dispatch(
            frame,
            token: frame.rootToken,
            digest: frame.rootDigest,
            action: #"{"kind":"move_window","position":{"x":\#(target.x),"y":\#(target.y)}}"#,
            observeAfter: true
        )

        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual(result["outcome"] as? String, "ok")
        XCTAssertEqual(result["tier"] as? String, "ax")
        XCTAssertEqual(result["path"] as? String, "ax_attribute")
        XCTAssertEqual(result["effect"] as? String, "confirmed", "an unclamped move lands where it was asked")
        XCTAssertEqual((result["verification"] as? [String: Any])?["method"] as? String, "value_readback")
        XCTAssertEqual(frontmostPid(), front, "a window move does not change who is in front")

        // Vector 58's first half, asserted directly off the window server rather
        // than through the re-observation below. The re-observation costs an
        // Accessibility walk of its own, and a walk is long enough to hide the
        // lag it is supposed to be catching; this read happens the instant the
        // dispatch answered.
        XCTAssertEqual(
            try XCTUnwrap(
                HostWindowInventory.onScreenWindows().first { $0.windowId == window.windowId }
            ).bounds.origin.x,
            Double(target.x),
            accuracy: 1,
            "the executor does not answer until the window server agrees with the write"
        )

        // Vector 58's second half. This is what fails against an executor that
        // returns on the application's acknowledgement: the window list still
        // reports the old origin, `observe` matches the AX window against that
        // frame to within a point, nothing matches, and the answer is
        // `window_gone` for a window sitting in plain sight.
        var observed = try XCTUnwrap(
            result["snapshot"] as? [String: Any],
            "the frame after the move is missing: \(result["postObservationError"] ?? "no error either")"
        )
        var bounds = try XCTUnwrap((observed["target"] as? [String: Any])?["bounds"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(bounds["x"] as? Double), Double(target.x), accuracy: 1,
            "the window server agreed before we answered"
        )
        XCTAssertEqual(try XCTUnwrap(bounds["y"] as? Double), Double(target.y), accuracy: 1)

        // --- resize, against the frame the move handed back ---

        frame = try LiveFrame(snapshot: observed)
        front = frontmostPid()
        let biggerSize = CGSize(width: originalSize.width + 90, height: originalSize.height + 70)

        result = try session.dispatch(
            frame,
            token: frame.rootToken,
            digest: frame.rootDigest,
            action: #"{"kind":"resize_window","size":{"width":\#(biggerSize.width),"height":\#(biggerSize.height)}}"#,
            observeAfter: true
        )

        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual(result["effect"] as? String, "confirmed", "TextEdit's window is resizable")
        XCTAssertEqual(result["path"] as? String, "ax_attribute")
        XCTAssertEqual(frontmostPid(), front, "a window resize does not change who is in front")

        observed = try XCTUnwrap(result["snapshot"] as? [String: Any])
        bounds = try XCTUnwrap((observed["target"] as? [String: Any])?["bounds"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(bounds["width"] as? Double), Double(biggerSize.width), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(bounds["height"] as? Double), Double(biggerSize.height), accuracy: 1)

        // --- vector 57: the clamp ---
        //
        // macOS keeps a window reachable, and it does it to a rule the executor
        // cannot restate: measured, `(99999, 300)` came back `(1687, -52)` with
        // *both* coordinates changed. The executor writes what it was asked for
        // and reports what it got, because a second clamp on top of that one
        // would disagree with it and a refusal reads to a model as a bad
        // argument.
        frame = try LiveFrame(snapshot: observed)
        front = frontmostPid()

        result = try session.dispatch(
            frame,
            token: frame.rootToken,
            digest: frame.rootDigest,
            action: #"{"kind":"move_window","position":{"x":99999,"y":300}}"#,
            observeAfter: true
        )

        XCTAssertEqual(result["ok"] as? Bool, true, "a clamped move happened; it is not a refusal")
        XCTAssertEqual(result["outcome"] as? String, "ok")
        XCTAssertEqual(
            result["effect"] as? String,
            "unverifiable",
            "it moved, so not `suspected_noop`; not to where it was asked, so not `confirmed`"
        )
        XCTAssertEqual(
            (result["verification"] as? [String: Any])?["method"] as? String,
            "value_readback",
            "`unverifiable` with a method named means the executor looked and could not confirm"
        )
        XCTAssertEqual(frontmostPid(), front)

        observed = try XCTUnwrap(result["snapshot"] as? [String: Any])
        bounds = try XCTUnwrap((observed["target"] as? [String: Any])?["bounds"] as? [String: Any])
        let landedX = try XCTUnwrap(bounds["x"] as? Double)
        XCTAssertLessThan(landedX, 99_999, "macOS clamped it, and where it landed is reported as a fact")
        XCTAssertNotEqual(landedX, Double(target.x), "it did move")

        // --- vector 56: a window action against something that is not the window ---
        //
        // The other half of the unit vector. There the fixture element was inside
        // the window and the refusal could have come from anywhere; here the same
        // action against the same window's root has just succeeded three times,
        // so the refusal is the gate and nothing else.
        frame = try LiveFrame(snapshot: observed)
        let child = try XCTUnwrap(frame.firstNonRoot, "TextEdit's window has no children to address")

        result = try session.dispatch(
            frame,
            token: child.token,
            digest: child.digest,
            action: #"{"kind":"move_window","position":{"x":100,"y":100}}"#,
            observeAfter: false
        )

        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "element_not_actionable")
        XCTAssertEqual(result["outcome"] as? String, "refused")
        XCTAssertEqual(result["path"] as? String, "none")
    }

    // MARK: - Vector 56: an attribute the application will not have written

    /// Calculator's window advertises `AXSize` and refuses to have it written —
    /// the raw write comes back `kAXErrorFailure`. The executor asks
    /// `AXUIElementIsAttributeSettable` first so the answer is
    /// `element_not_actionable`, which the model can act on, rather than a fault.
    /// Its position is settable on the same window, which is what makes this a
    /// vector rather than an observation about Calculator being unreachable.
    func testAWindowThatWillNotBeResizedIsRefusedRatherThanReportedDone() throws {
        try requireLiveDesktop()

        let app = try backgroundLaunched("Calculator")
        let (window, element) = try windowAndElement(pid: app.pid)

        let originalPosition = try XCTUnwrap(HostAX.point(element, kAXPositionAttribute))
        let originalSize = try XCTUnwrap(HostAX.size(element, kAXSizeAttribute))
        defer {
            _ = HostAX.write(element, kAXPositionAttribute, point: originalPosition)
            settleWindowServer(window, element)
        }

        guard !HostAX.isSettable(element, kAXSizeAttribute) else {
            throw XCTSkip("Calculator's AXSize became settable; this vector needs a window that refuses it")
        }

        let session = try LiveSession()
        defer { session.end() }

        var frame = try session.observe(window)
        let front = frontmostPid()

        let refused = try session.dispatch(
            frame,
            token: frame.rootToken,
            digest: frame.rootDigest,
            action: #"{"kind":"resize_window","size":{"width":900,"height":600}}"#,
            observeAfter: false
        )

        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "element_not_actionable")
        XCTAssertEqual(refused["outcome"] as? String, "refused")
        XCTAssertEqual(refused["path"] as? String, "none")
        XCTAssertEqual(refused["effect"] as? String, "unverifiable")
        XCTAssertEqual((refused["verification"] as? [String: Any])?["method"] as? String, "none")
        XCTAssertEqual(
            HostAX.size(element, kAXSizeAttribute)?.width,
            originalSize.width,
            "a refusal touches nothing"
        )

        // §4.1 — a refused dispatch does not spend its snapshot, so the same
        // frame carries the move that proves the refusal was about `AXSize` and
        // not about the window, the token or the root gate.
        let moved = try session.dispatch(
            frame,
            token: frame.rootToken,
            digest: frame.rootDigest,
            action: #"{"kind":"move_window","position":{"x":\#(originalPosition.x - 40),"y":\#(originalPosition.y)}}"#,
            observeAfter: true
        )

        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        XCTAssertEqual(moved["effect"] as? String, "confirmed")
        XCTAssertEqual(frontmostPid(), front, "neither the refusal nor the move changed who is in front")

        // --- `secondary_action: "raise"`, which is not new and is measured here
        //     for the invariant only ---
        //
        // Calculator advertises `AXRaise` and answers it with
        // `kAXErrorAttributeUnsupported`. What is asserted is that an action the
        // application will not perform never arrives as an `ok` that did nothing,
        // and that raising never takes the foreground either way.
        frame = try LiveFrame(snapshot: try XCTUnwrap(moved["snapshot"] as? [String: Any]))
        let raised = try session.dispatch(
            frame,
            token: frame.rootToken,
            digest: frame.rootDigest,
            action: #"{"kind":"secondary_action","action":"raise"}"#,
            observeAfter: false
        )

        XCTAssertEqual(frontmostPid(), front, "AXRaise reorders the z-order; it does not activate")
        if raised["ok"] as? Bool == false {
            XCTAssertEqual(raised["outcome"] as? String, "failed", "attempted, and the OS said no")
            XCTAssertEqual(raised["path"] as? String, "ax_action", "which path was attempted is declared")
            XCTAssertEqual((raised["error"] as? [String: Any])?["code"] as? String, "dispatch_refused")
        } else {
            XCTAssertEqual(raised["path"] as? String, "ax_action")
            XCTAssertNotEqual(
                raised["effect"] as? String,
                "confirmed",
                "a bare AXUIElementPerformAction returning success is not confirmation"
            )
        }
    }

    // MARK: - Vector 58 and §14: minimising

    /// Minimising is background-safe and the executor confirms it. Restoring is
    /// not, which is why there is no `unminimize_window` on the wire — and the
    /// restore this test has to perform anyway is the standing measurement of it.
    func testMinimisingIsConfirmedAndOnlyRestoringTakesTheForeground() throws {
        try requireLiveDesktop()

        let app = try backgroundLaunched("Calculator")
        let (window, element) = try windowAndElement(pid: app.pid)

        let session = try LiveSession()
        defer { session.end() }

        let frame = try session.observe(window)
        let front = frontmostPid()
        try XCTSkipIf(front == app.pid, "Calculator is frontmost; this vector needs a background window")

        let result = try session.dispatch(
            frame,
            token: frame.rootToken,
            digest: frame.rootDigest,
            action: #"{"kind":"minimize_window"}"#,
            observeAfter: true
        )

        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual(result["outcome"] as? String, "ok")
        XCTAssertEqual(result["path"] as? String, "ax_attribute")
        XCTAssertEqual(result["effect"] as? String, "confirmed")
        XCTAssertEqual((result["verification"] as? [String: Any])?["method"] as? String, "value_readback")
        XCTAssertEqual(frontmostPid(), front, "a minimise cannot bring its target forward")

        // §6.1 — the window really has left the screen, and the executor waited
        // for the window server to say so rather than racing the animation. The
        // post-observation therefore reports the truth rather than a stale frame.
        XCTAssertNil(result["snapshot"], "a minimized window is not on screen")
        XCTAssertEqual(
            (result["postObservationError"] as? [String: Any])?["code"] as? String,
            "window_gone"
        )
        XCTAssertNil(
            HostWindowInventory.onScreenWindows().first { $0.windowId == window.windowId },
            "the window server agreed before the dispatch answered"
        )

        // §14 — the restore, performed outside the protocol because the protocol
        // has no way to ask for it. This is the measurement: writing
        // `AXMinimized = false` hands the foreground to the target, which is why
        // there is no `unminimize_window` for a model to reach.
        XCTAssertEqual(HostAX.write(element, kAXMinimizedAttribute, flag: false), .success)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(
            frontmostPid(),
            app.pid,
            "restoring a minimized window activates its application — the finding §14 records"
        )
        XCTAssertNotNil(HostWindowInventory.onScreenWindows().first { $0.windowId == window.windowId })
    }

    // MARK: - Preconditions

    private func requireLiveDesktop() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_WINDOW_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_WINDOW_LIVE_TEST=1 to run the live window dispatch tests")
        }
        // `AXIsProcessTrusted` asks; the prompting variant would block the run on
        // a dialog nobody is there to answer.
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not granted to the process running these tests")
        }
        guard !hostScreenIsLocked() else {
            throw XCTSkip("The screen is locked, so the tree is the menu bar and nothing else")
        }
    }

    private func frontmostPid() -> pid_t? {
        LiveApplicationInventory.frontmostApplicationPid()
    }

    /// Running, without having taken the foreground to get there, and left
    /// running afterwards.
    private func backgroundLaunched(_ name: String) throws -> RunningAppDescriptor {
        let resolved = Outcome()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            resolved.result = Result { try AppDiscovery.resolve(name, waitFor: 20) }
            finished.signal()
        }

        guard finished.wait(timeout: .now() + 40) == .success else {
            throw XCTSkip("\(name) never resolved")
        }
        return try XCTUnwrap(resolved.result).get()
    }

    /// Its on-screen ordinary window **and** the AX element that matches it,
    /// waited for together.
    ///
    /// Two waits, and neither is optional. A launch returns before the window is
    /// mapped, measured at 1.3–3.2 s against 2.3–4.5 s (§5.7). And a window that
    /// has just been moved — by the test before this one putting it back, for
    /// instance — is reported at its old frame by the window list for another
    /// 26–172 ms while Accessibility already reports the new one, so
    /// `HostAX.window`, which matches the two to within a point, answers `nil`
    /// for a window that is plainly there. That is the same lag §6.1 makes the
    /// executor wait out, met from the other side.
    private func windowAndElement(pid: pid_t) throws -> (HostWindowInfo, AXUIElement) {
        let deadline = Date().addingTimeInterval(20)
        var lastSeen: HostWindowInfo?

        while Date() < deadline {
            if let window = HostWindowInventory.onScreenWindows()
                .first(where: { $0.pid == pid && $0.layer == 0 && $0.bounds.width > 64 && $0.bounds.height > 64 }) {
                lastSeen = window
                if let element = HostAX.window(pid: window.pid, windowId: window.windowId, bounds: window.bounds) {
                    return (window, element)
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw XCTSkip(
            lastSeen == nil
                ? "pid \(pid) came up with no ordinary window"
                : "the window list and Accessibility never agreed on pid \(pid)'s frame"
        )
    }

    /// Waits for the window server to report the frame Accessibility already
    /// does, so a restore does not leave the machine mid-flight for whatever runs
    /// next. It is the executor's own wait, spelled out here rather than reached
    /// into, because a test that shares the code under test proves nothing.
    private func settleWindowServer(_ window: HostWindowInfo, _ element: AXUIElement) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard let position = HostAX.point(element, kAXPositionAttribute),
                  let listed = HostWindowInventory.onScreenWindows().first(where: { $0.windowId == window.windowId })
            else {
                return
            }
            if abs(listed.bounds.origin.x - position.x) < 1, abs(listed.bounds.origin.y - position.y) < 1 {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private final class Outcome: @unchecked Sendable {
        var result: Result<RunningAppDescriptor, Error>?
    }

    // MARK: - A frame, and the executor speaking the real wire

    /// One `snapshot` payload, with the two things every dispatch here quotes.
    /// The root is `elements[0]` by construction — §4.3 roots the walk at the
    /// window — and the assertion is here rather than at each use so a change to
    /// that fails once and loudly.
    private struct LiveFrame {
        let id: String
        let rootToken: String
        let rootDigest: String
        let firstNonRoot: (token: String, digest: String)?

        init(snapshot: [String: Any]) throws {
            id = try XCTUnwrap(snapshot["snapshotId"] as? String)
            let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])
            let root = try XCTUnwrap(elements.first)
            XCTAssertEqual(root["depth"] as? Int, 0, "the walk is rooted at the window")
            rootToken = try XCTUnwrap(root["token"] as? String)
            rootDigest = try XCTUnwrap(root["digest"] as? String)

            firstNonRoot = elements
                .first { ($0["depth"] as? Int ?? 0) > 0 }
                .flatMap { child in
                    guard let token = child["token"] as? String, let digest = child["digest"] as? String else {
                        return nil
                    }
                    return (token: token, digest: digest)
                }
        }
    }

    /// A handshaken server with one session, driven through `handle(line:)` on
    /// the real wire. Responses arrive off whichever lane produced them and are
    /// handed over through a semaphore.
    private final class LiveSession {
        private let server: HostProtocolServer
        private let inbox = ResponseInbox()
        private let imageDirectory: URL
        private var nextId = 10

        init() throws {
            imageDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("maka-cu-window-live-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

            let inbox = self.inbox
            server = HostProtocolServer(
                output: HostOutputWriter { inbox.append($0) },
                environment: HostLiveEnvironment()
            )

            // `allowGlobalPointer` is false, as it is in production.
            server.handle(line: #"""
            {"jsonrpc":"2.0","id":1,"method":"host.hello","params":{"protocol":"\#(makaCuProtocolVersion)","hostPid":\#(ProcessInfo.processInfo.processIdentifier),"imageDir":"\#(imageDirectory.path)","allowGlobalPointer":false}}
            """#)
            _ = try inbox.next()
            server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
            _ = try inbox.next()
        }

        func end() {
            server.handle(line: #"{"jsonrpc":"2.0","id":99,"method":"session.end","params":{"session":"s1"}}"#)
            _ = try? inbox.next()
            try? FileManager.default.removeItem(at: imageDirectory)
        }

        /// No image: none of these vectors dispatches a point, and a capture is
        /// seconds this test does not need to spend.
        func observe(_ window: HostWindowInfo) throws -> LiveFrame {
            nextId += 1
            server.handle(line: #"""
            {"jsonrpc":"2.0","id":\#(nextId),"method":"observe","params":{"session":"s1","target":{"kind":"window","appId":"\#(window.appId)","pid":\#(window.pid),"processGeneration":"\#(hostProcessGeneration(hostProcessStartTime(pid: window.pid) ?? 0))","windowId":\#(window.windowId)},"includeImage":false}}
            """#)

            let result = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])
            guard result["ok"] as? Bool == true else {
                throw ComputerUseError.message("observe: \(result)")
            }
            return try LiveFrame(snapshot: try XCTUnwrap(result["snapshot"] as? [String: Any]))
        }

        func dispatch(
            _ frame: LiveFrame,
            token: String,
            digest: String,
            action: String,
            observeAfter: Bool
        ) throws -> [String: Any] {
            nextId += 1
            let after = observeAfter ? #","observeAfter":{"includeImage":false,"settle":"none"}"# : ""
            server.handle(line: #"""
            {"jsonrpc":"2.0","id":\#(nextId),"method":"dispatch.element","params":{"session":"s1","snapshotId":"\#(frame.id)","toolCallId":"call_\#(nextId)","elementToken":"\#(token)","expectElementDigest":"\#(digest)","action":\#(action)\#(after)}}
            """#)

            return try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])
        }
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
