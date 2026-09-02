import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §12 vector 54 — the half of `dispatch.key` no unit test can reach: whether a
/// key posted to a **background** application arrives at all.
///
///     OPEN_COMPUTER_USE_RUN_KEY_DELIVERY_LIVE_TEST=1 \
///         swift test --filter HostKeyDeliveryLiveTests
///
/// `CGEventPostToPid` delivers whatever the executor put on the event, and the
/// executor put no characters on it. A key code is half an event; the character
/// is the half an application acts on, and an application that is not frontmost
/// does not supply it for itself. `typeText` set the string and worked;
/// `pressKey` never did, so every `{ "kind": "key" }` this executor ever posted
/// did nothing, reported `outcome: ok`, and told the model a request had
/// succeeded that could not have. §14 measured it one key at a time and this
/// vector is the standing assertion.
///
/// The unit half asserts the event carries the character AppKit binds rather
/// than the layout's translation of the key code. It cannot assert the
/// application acts on it, and the two are different claims: an executor that
/// sets the character but posts to the wrong place passes the unit half.
///
/// **The target is never activated.** That is the difference between this vector
/// and 53, which activates deliberately to measure a *verdict* without delivery
/// confounding it. Here delivery is the subject, and background delivery is the
/// only delivery this protocol allows: §6.4 forbids activating the application,
/// raising its window or changing the frontmost app. The frontmost pid is
/// asserted unchanged across the whole run, which is what makes the effects
/// below evidence of a key that landed in the background rather than of a
/// foreground the test quietly took.
///
/// Escape is not asserted here, and its absence is a measurement rather than an
/// omission. On a background `NSTextView` it reaches `cancelOperation:`, whose
/// answer is a completion panel — and measured, no window at any layer appears
/// for the target while it is not the active application, so this fixture cannot
/// tell a delivered Escape from a dropped one. It was measured elsewhere and it
/// lands: posted at a background Calculator, `Escape` cleared the entry two
/// digit keys had just put in the display, with the frontmost application
/// unchanged throughout. Calculator is not a vector here because its focused
/// element does not appear in the observation at all — `focusedElementToken` is
/// `nil` — so `dispatch.key`, which requires one, cannot address it.
///
/// The document is this test's own, in the temporary directory. TextEdit is left
/// running; only the window this test opened is closed, and its changes are
/// discarded.
///
/// Every wait here is a semaphore. `wait(for:)` and `RunLoop.run` both spin the
/// main run loop, which thaws exactly the timings a live test exists to catch —
/// the executor's main thread sits in `readLine` and spins nothing.
final class HostKeyDeliveryLiveTests: XCTestCase {
    private let marker = "maka-cu key delivery live vector 54"

    func testAKeyPostedToABackgroundApplicationArrives() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_KEY_DELIVERY_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_KEY_DELIVERY_LIVE_TEST=1 to run the live key delivery test")
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

        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        XCTAssertNotEqual(
            frontBefore,
            window.pid,
            "the launch asked not to activate, and a vector about background delivery needs a background target"
        )

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

        var nextId = 3
        func dispatch(key: String, modifiers: [String] = []) throws -> [String: Any] {
            let observation = try observe(server: server, inbox: inbox, id: nextId, window: window)
            nextId += 1
            let text = try XCTUnwrap(
                try textArea(in: observation),
                "the document did not come up with a readable text area"
            )
            let encodedModifiers = modifiers.map { "\"\($0)\"" }.joined(separator: ",")

            server.handle(line: #"""
            {"jsonrpc":"2.0","id":\#(nextId),"method":"dispatch.key","params":{"session":"s1","snapshotId":"\#(try XCTUnwrap(observation["snapshotId"] as? String))","toolCallId":"call_\#(nextId)","focusToken":"\#(try XCTUnwrap(text["token"] as? String))","expectElementDigest":"\#(try XCTUnwrap(text["digest"] as? String))","focusPolicy":"acquire","action":{"kind":"key","key":"\#(key)","modifiers":[\#(encodedModifiers)]},"observeAfter":{"includeImage":false,"settle":"quiesce"}}}
            """#)
            nextId += 1
            let result = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])
            debug(key, result)

            XCTAssertEqual(result["ok"] as? Bool, true, "\(key): \(result)")
            XCTAssertEqual(result["outcome"] as? String, "ok", key)
            XCTAssertEqual(
                NSWorkspace.shared.frontmostApplication?.processIdentifier,
                frontBefore,
                "\(key) took the foreground, which §6.4 forbids and which would make every effect below worthless"
            )
            return result
        }

        // The caret starts at the top of the document, which is where the
        // arrow-key measurement in §14 starts.
        XCTAssertEqual(try caret(pid: window.pid)?.location, 0)
        let original = try XCTUnwrap(try textArea(in: try observe(server: server, inbox: inbox, id: 200, window: window))?["value"] as? String)
        XCTAssertTrue(original.contains(marker))

        // 1. `Right`. The key §14 measured landing only once it carried U+F703,
        //    and the plainest evidence there is: the insertion point moved and
        //    the document did not change.
        _ = try dispatch(key: "Right")
        XCTAssertEqual(
            try caret(pid: window.pid)?.location,
            1,
            "`Right` moves the insertion point one character, and a background application acts on it once the event carries the character"
        )

        _ = try dispatch(key: "Right")
        XCTAssertEqual(try caret(pid: window.pid)?.location, 2, "twice, so the first was not a one-off of the open")

        // 2. `Left`, back again. The pair is what rules out an insertion point
        //    that drifted rather than one that was driven.
        _ = try dispatch(key: "Left")
        XCTAssertEqual(try caret(pid: window.pid)?.location, 1)

        // 3. `Down` and `Up`, so all four arrows are covered rather than the two
        //    that happen to be consecutive code points. The document is one line
        //    of text and a trailing newline, so down from the first line lands on
        //    the empty second one.
        //
        //    `Home` and `End` are not asserted here, and their absence is not an
        //    omission: on macOS they are bound to `scrollToBeginningOfDocument:`
        //    and `scrollToEndOfDocument:`, which move the view and not the
        //    insertion point — measured, the caret does not move for either. A
        //    document that fits its window has nothing to scroll, so this fixture
        //    cannot tell a delivered `End` from a dropped one, and asserting
        //    either way would be asserting something this test did not see.
        _ = try dispatch(key: "Down")
        XCTAssertEqual(
            try caret(pid: window.pid)?.location,
            original.utf16.count,
            "`Down` moves to the empty last line, which is the end of the document"
        )
        _ = try dispatch(key: "Up")
        XCTAssertEqual(try caret(pid: window.pid)?.location, 1, "and back to the column it left")

        // 4. `Tab`, `Return`, `Backspace`, `ForwardDelete` — the ones that change
        //    the document, so the evidence is the application's own value rather
        //    than a caret. Each expectation is written against the insertion
        //    point the arrows above left behind.
        let head = String(original.prefix(1))
        let tail = String(original.dropFirst(1))

        let tabbed = try dispatch(key: "Tab")
        XCTAssertEqual(
            try value(in: tabbed),
            head + "\t" + tail,
            "`Tab` inserts a tab at the insertion point"
        )

        let returned = try dispatch(key: "Return")
        XCTAssertEqual(
            try value(in: returned),
            head + "\t\n" + tail,
            "`Return` inserts a newline"
        )

        // `Backspace` is the one whose character is not the one its name
        // suggests: the Mac backspace key produces U+007F, not the U+0008 the
        // name points at.
        let deleted = try dispatch(key: "Backspace")
        XCTAssertEqual(
            try value(in: deleted),
            head + "\t" + tail,
            "`Backspace` deletes the character before the insertion point"
        )

        // And `ForwardDelete` is the other half of the pair the wire refuses to
        // spell `Delete`: it takes the character on the other side of the caret.
        let forwardDeleted = try dispatch(key: "ForwardDelete")
        XCTAssertEqual(
            try value(in: forwardDeleted),
            head + "\t" + String(tail.dropFirst()),
            "`ForwardDelete` deletes the character after the insertion point, which is the key `Delete` could have meant"
        )

        // 5. A printable character, which is the other 94 members of the closed
        //    set and reaches the application by the same route.
        let typed = try dispatch(key: "z")
        XCTAssertEqual(
            try value(in: typed),
            head + "\tz" + String(tail.dropFirst()),
            "a printable key posts the character it names"
        )

        let shifted = try dispatch(key: "z", modifiers: ["shift"])
        XCTAssertEqual(
            try value(in: shifted),
            head + "\tzZ" + String(tail.dropFirst()),
            "and `shift` asks for the other character on that key"
        )

        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
            frontBefore,
            "nothing in this run may change who is in front"
        )
    }

    // MARK: - Helpers

    /// Off unless asked for. A live vector that fails is answered by looking at
    /// the wire, and reconstructing the run to get it is the slow way.
    private func debug(_ label: String, _ result: [String: Any]) {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_LIVE_DEBUG"] == "1" else {
            return
        }

        let post = result["snapshot"] as? [String: Any]
        print("DEBUG \(label): outcome=\(result["outcome"] ?? "?") effect=\(result["effect"] ?? "?") error=\(result["error"] ?? "-")")
        print("DEBUG \(label): value=\(String(describing: (try? textArea(in: post ?? [:]))??["value"]))")
    }

    /// The document's text, read out of the executor's own post-dispatch
    /// observation — the application answering for what it did with the key,
    /// rather than the test reading the machine a second way.
    private func value(in result: [String: Any]) throws -> String? {
        let snapshot = try XCTUnwrap(result["snapshot"] as? [String: Any])
        return try textArea(in: snapshot)?["value"] as? String
    }

    /// The insertion point in the focused text element, read straight from
    /// Accessibility rather than from the observation: `selectedText` is the
    /// selected *string*, and a caret that moved without selecting anything is
    /// empty on both sides of it.
    private func caret(pid: pid_t) throws -> CFRange? {
        guard let focused = HostAX.focusedElement(pid: pid) else {
            return nil
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value else {
            return nil
        }

        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return nil
        }

        return range
    }

    private func makeDocument() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-key-delivery-\(UUID().uuidString).txt")
        try (marker + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// TextEdit showing that document, without taking the foreground — which is
    /// the condition this whole vector is about, so it is asserted rather than
    /// assumed by the caller.
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
                // The window server maps the window before the application has
                // finished making its text view the focused element; a key posted
                // into that gap goes nowhere.
                Thread.sleep(forTimeInterval: 1)
                return first
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        throw ComputerUseError.message("TextEdit never showed a window titled \(name)")
    }

    /// Closes the one window this test opened, discarding what it typed, and
    /// removes the file. Through AppleScript rather than through the executor:
    /// the keys are the subject matter here, and a cleanup step that can fail the
    /// way the thing under test can fail is not a cleanup step.
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

    /// The document's text area. TextEdit's window holds more than one text
    /// element and only one of them is the document, so it is found by role and
    /// checked against the marker where the value still carries it.
    private func textArea(in snapshot: [String: Any]) throws -> [String: Any]? {
        let elements = snapshot["elements"] as? [[String: Any]] ?? []
        return elements.first { ($0["value"] as? String)?.contains(marker) == true }
            ?? elements.first { $0["role"] as? String == "AXTextArea" }
    }

    private func makeImageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-key-delivery-\(UUID().uuidString)", isDirectory: true)
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
