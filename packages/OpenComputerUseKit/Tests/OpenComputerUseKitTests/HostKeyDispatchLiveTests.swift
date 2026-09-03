import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §12 vector 53 — the half of `dispatch.key`'s effect rule that no unit test can
/// reach: whether a shortcut is judged by something that has any bearing on it.
///
///     OPEN_COMPUTER_USE_RUN_KEY_LIVE_TEST=1 \
///         swift test --filter HostKeyDispatchLiveTests
///
/// The executor read the focused element's `AXValue` either side of every key it
/// posted and reported `suspected_noop` whenever it had not moved. For `type`
/// that is the right question asked of the right element. For a *key* it is a
/// question about something else entirely, and the answer is "unchanged" whether
/// the key landed or not.
///
/// It survived a full unit matrix because a fake `AXUIElement` has no value to
/// read: both sides come back `nil`, the executor takes its own "nothing to
/// check" arm, and the answer is the `unverifiable` the fix produces. The defect
/// is only visible against an element that really has a value, which means a real
/// text view in a real application.
///
/// **This test activates its target, and that is deliberate.** §14 records a
/// delivery defect this vector must not measure instead: `cmd+A` is a main-menu
/// key equivalent, `performKeyEquivalent:` is reached through `NSApp`'s key
/// window, and a background application has none — so against a background
/// window the one key this vector can send goes nowhere, and the vector would be
/// measuring delivery rather than the verdict, passing for the wrong reason
/// before the fix and after it alike. Activating removes the confound and
/// reproduces the field case exactly: a model pressing `cmd+A` on the document
/// the user is looking at. Background delivery is vector 54's subject, in
/// `HostKeyDeliveryLiveTests`, which never activates anything.
///
/// What is *not* relaxed is the executor's own invariant. The frontmost
/// application is asserted to be unchanged **across each dispatch** — the test
/// may take the foreground, the executor may not — and the application that had
/// it is put back afterwards.
///
/// The document is this test's own, in the temporary directory, because the
/// user's documents are not fixtures. TextEdit is left running; only the window
/// this test opened is closed.
///
/// Every wait here is a semaphore. `wait(for:)` and `RunLoop.run` both spin the
/// main run loop, which thaws exactly the timings a live test exists to catch —
/// the executor's main thread sits in `readLine` and spins nothing.
final class HostKeyDispatchLiveTests: XCTestCase {
    private let marker = "maka-cu key dispatch live vector 53"

    func testAShortcutIsNotReportedAsANoopBecauseTheFocusedValueDidNotMove() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_KEY_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_KEY_LIVE_TEST=1 to run the live key dispatch test")
        }

        // `AXIsProcessTrusted` asks; the prompting variant would block the run on
        // a dialog nobody is there to answer.
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not granted to the process running these tests")
        }
        guard !hostScreenIsLocked() else {
            throw XCTSkip("The screen is locked, so the tree is the menu bar and nothing else")
        }
        guard FileManager.default.fileExists(atPath: "/System/Applications/TextEdit.app") else {
            throw XCTSkip("TextEdit is not installed")
        }

        let document = try makeDocument()
        let window = try openInBackground(document)
        defer { closeDocument(document) }

        let restore = NSWorkspace.shared.frontmostApplication
        defer {
            if let restore, let identifier = restore.bundleIdentifier {
                let osascript = Process()
                osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                osascript.arguments = ["-e", "tell application id \"\(identifier)\" to activate"]
                osascript.standardError = FileHandle.nullDevice
                try? osascript.run()
                osascript.waitUntilExit()
            }
        }
        try activate(pid: window.pid)

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
        defer {
            server.handle(line: #"{"jsonrpc":"2.0","id":99,"method":"session.end","params":{"session":"s1"}}"#)
            _ = try? inbox.next()
        }

        // 1. The text this test wrote, read back through Accessibility. Without a
        //    value under the focused element there is nothing for the broken
        //    readback to compare, and the vector proves nothing.
        let observation = try observe(server: server, inbox: inbox, id: 3, window: window)
        let text = try XCTUnwrap(
            try textArea(in: observation),
            "the document did not come up with a readable text area"
        )
        XCTAssertTrue(
            (text["value"] as? String)?.contains(marker) == true,
            "the focused text area must carry a value, or the readback has nothing to be wrong about"
        )
        XCTAssertNil(
            (observation["selectedText"] as? [String: Any])?["text"] as? String,
            "a freshly opened document has an empty selection, which is what `cmd+A` will change"
        )

        // 2. `cmd+A`: the field case. A menu shortcut whose whole effect is the
        //    selection, leaving the focused element's value exactly where it was
        //    — which is what the executor used to answer with.
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":4,"method":"dispatch.key","params":{"session":"s1","snapshotId":"\#(try XCTUnwrap(observation["snapshotId"] as? String))","toolCallId":"call_select_all","focusToken":"\#(try XCTUnwrap(text["token"] as? String))","expectElementDigest":"\#(try XCTUnwrap(text["digest"] as? String))","focusPolicy":"acquire","action":{"kind":"key","key":"a","modifiers":["command"]},"observeAfter":{"includeImage":false,"settle":"quiesce"}}}
        """#)
        let selected = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])
        debug("selected", selected)

        XCTAssertEqual(selected["ok"] as? Bool, true, "\(selected)")
        XCTAssertEqual(selected["outcome"] as? String, "ok")
        XCTAssertEqual(selected["path"] as? String, "cg_event_pid")
        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
            window.pid,
            "the executor does not change who is in front; the test put TextEdit there and it is still there"
        )

        // The key landed, and the executor's own re-observation is what says so.
        // Asserted before the verdict is, so a failure below reads as "the verdict
        // is wrong", never as "the key never arrived".
        let post = try XCTUnwrap(selected["snapshot"] as? [String: Any])
        XCTAssertEqual(
            (post["selectedText"] as? [String: Any])?["text"] as? String,
            text["value"] as? String,
            "`cmd+A` selects the document, and the observation after the dispatch is where that shows"
        )
        XCTAssertEqual(
            (try textArea(in: post))?["value"] as? String,
            text["value"] as? String,
            "and it leaves the value alone, which is the reason the readback could never see it"
        )

        XCTAssertNotEqual(
            selected["effect"] as? String,
            "suspected_noop",
            "the key landed; an executor that says nothing happened is reporting a check it had no business making"
        )
        let verification = try XCTUnwrap(selected["verification"] as? [String: Any])
        XCTAssertNotEqual(
            verification["method"] as? String,
            "value_readback",
            "the focused element's value is not what a command key changes"
        )
        XCTAssertEqual(
            verification["method"] as? String,
            "tree_delta",
            "settling was asked for, so the window across it is the evidence a key gets"
        )

        // 3. Typing keeps the readback, on the same element, under the same
        //    settle. The split is per action, not per element.
        let second = try observe(server: server, inbox: inbox, id: 5, window: window)
        let reread = try XCTUnwrap(try textArea(in: second))
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":6,"method":"dispatch.key","params":{"session":"s1","snapshotId":"\#(try XCTUnwrap(second["snapshotId"] as? String))","toolCallId":"call_type","focusToken":"\#(try XCTUnwrap(reread["token"] as? String))","expectElementDigest":"\#(try XCTUnwrap(reread["digest"] as? String))","focusPolicy":"acquire","action":{"kind":"type","text":"typed"},"observeAfter":{"includeImage":false,"settle":"quiesce"}}}
        """#)
        let typed = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])
        debug("typed", typed)

        XCTAssertEqual(typed["ok"] as? Bool, true, "\(typed)")
        XCTAssertEqual(
            (typed["verification"] as? [String: Any])?["method"] as? String,
            "value_readback",
            "typing writes into the element the request named, and that value is still the evidence"
        )
        XCTAssertEqual(typed["effect"] as? String, "confirmed")
    }

    // MARK: - Helpers

    /// Off unless asked for. A live vector that fails is answered by looking at
    /// the wire, and reconstructing the run to get it is the slow way.
    private func debug(_ label: String, _ result: [String: Any]) {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_LIVE_DEBUG"] == "1" else {
            return
        }

        let post = result["snapshot"] as? [String: Any]
        print("DEBUG \(label): effect=\(result["effect"] ?? "?") verification=\(result["verification"] ?? "?")")
        print("DEBUG \(label): selectedText=\(String(describing: post?["selectedText"]))")
        print("DEBUG \(label): focusedValue=\(String(describing: (try? textArea(in: post ?? [:]))??["value"]))")
    }

    private func makeDocument() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-key-live-\(UUID().uuidString).txt")
        try (marker + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// TextEdit showing that document. Opened in the background — the foreground
    /// this test takes it wants to take deliberately, a moment later, and a launch
    /// that grabs it on the way in would hide a launch that did not.
    private func openInBackground(_ document: URL) throws -> HostWindowInfo {
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-g", "-a", "TextEdit", document.path]
        try launch.run()
        launch.waitUntilExit()
        guard launch.terminationStatus == 0 else {
            throw ComputerUseError.message("open exited \(launch.terminationStatus)")
        }

        // A launch returns before the window is mapped — measured at 1.3–3.2 s
        // against 2.3–4.5 s (§5.7) — so the window is waited for, by title,
        // because the user may have TextEdit windows of their own open.
        let name = document.lastPathComponent
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let first = HostWindowInventory.onScreenWindows()
                .first(where: { $0.layer == 0 && $0.title == name }) {
                return first
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        throw ComputerUseError.message("TextEdit never showed a window titled \(name)")
    }

    /// Through AppleScript, not `NSRunningApplication.activate()`: this process is
    /// a command-line test binary with no activation policy, and macOS will not
    /// let one application be brought forward by something that was never in the
    /// running order itself. Measured — the call returns and nothing moves.
    private func activate(pid: pid_t) throws {
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", "tell application id \"com.apple.TextEdit\" to activate"]
        osascript.standardError = FileHandle.nullDevice
        try osascript.run()
        osascript.waitUntilExit()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                // The window server is ahead of the application's own key-window
                // bookkeeping; a key posted into that gap goes nowhere.
                Thread.sleep(forTimeInterval: 0.5)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw XCTSkip("TextEdit would not take the foreground, and this vector needs a key that lands")
    }

    /// Closes the one window this test opened, discarding what it typed, and
    /// removes the file. Through AppleScript rather than through the executor:
    /// `cmd+W` is the executor's own subject matter, and a cleanup step that can
    /// fail the way the thing under test can fail is not a cleanup step.
    private func closeDocument(_ document: URL) {
        let script = """
        tell application "TextEdit"
          repeat with d in (documents as list)
            if name of d is "\(document.lastPathComponent)" then close d saving no
          end repeat
        end tell
        """
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", script]
        osascript.standardError = FileHandle.nullDevice
        try? osascript.run()
        osascript.waitUntilExit()
        try? FileManager.default.removeItem(at: document)
    }

    private func observe(
        server: HostProtocolServer,
        inbox: ResponseInbox,
        id: Int,
        window: HostWindowInfo
    ) throws -> [String: Any] {
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":\#(id),"method":"observe","params":{"session":"s1","target":{"kind":"window","appId":"\#(window.appId)","pid":\#(window.pid),"processGeneration":"\#(hostProcessGeneration(hostProcessStartTime(pid: window.pid) ?? 0))","windowId":\#(window.windowId)},"includeImage":false}}
        """#)
        let response = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])
        guard response["ok"] as? Bool == true else {
            throw ComputerUseError.message("observe: \((response["error"] as? [String: Any])?["code"] ?? "?")")
        }
        return try XCTUnwrap(response["snapshot"] as? [String: Any])
    }

    /// The document's text area, found by the text this test put in it rather
    /// than by role alone: TextEdit's window holds more than one text element and
    /// only one of them is the document.
    private func textArea(in snapshot: [String: Any]) throws -> [String: Any]? {
        let elements = snapshot["elements"] as? [[String: Any]] ?? []
        return elements.first { ($0["value"] as? String)?.contains(marker) == true }
            ?? elements.first { $0["role"] as? String == "AXTextArea" }
    }

    private func makeImageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-key-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
