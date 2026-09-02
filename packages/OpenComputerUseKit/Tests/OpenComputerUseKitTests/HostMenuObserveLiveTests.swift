import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §12 vector 62 — the half of §5.8 no unit test can reach.
///
///     OPEN_COMPUTER_USE_RUN_MENU_LIVE_TEST=1 \
///         swift test --filter HostMenuObserveLiveTests
///
/// Three of the four things asserted here are invisible to a fixture, and the
/// third is the one that would have shipped broken:
///
/// 1. A menu element's `frame` is suppressed. The value being suppressed is one
///    AppKit puts on a *real* unopened menu item — a degenerate `(0, 982, 0, 0)`
///    — and no fake node produces it, so a walk that forgot to suppress it looks
///    identical to one that did against every fixture in the suite.
/// 2. The suppression is applied at **both** ends of §4.3. The walk records the
///    frame and the dispatch-time probe recomputes it, and an executor that
///    suppressed it on the way out but not on the way back refuses every menu
///    dispatch `element_changed` / `changed: ["frame"]` — on an element nothing
///    has touched, on every application. This is the third time that seam has
///    been the defect; the first two were `ancestorRoles`.
/// 3. `AXPress` reaches a menu item of an application that is not in front, and
///    reaches it without putting it there.
///
/// Calculator is the target because `显示 > 基础` and `显示 > 科学` are a
/// reversible pair whose effect is visible from *outside* the application — the
/// window resizes — so "did it land" is a measurement rather than a judgement.
/// That matters more here than anywhere else in this suite: a menu press with a
/// side effect the test cannot undo is not a test, it is damage. Nothing here
/// presses an item that saves, deletes, prints, quits or opens a panel.
///
/// It is launched in the background and left running: this test does not own it.
///
/// Every wait is a semaphore. `wait(for:)` and `RunLoop.run` both spin the main
/// run loop, which thaws exactly the timings a live test exists to catch — the
/// executor's main thread sits in `readLine` and spins nothing.
final class HostMenuObserveLiveTests: XCTestCase {
    func testABackgroundApplicationsMenuIsReadableAndItsItemsArePressable() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_MENU_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_MENU_LIVE_TEST=1 to run the live menu test")
        }

        // `AXIsProcessTrusted` asks; the prompting variant would block the run on
        // a dialog nobody is there to answer.
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not granted to the process running these tests")
        }
        guard !hostScreenIsLocked() else {
            throw XCTSkip("The screen is locked, so the tree is the menu bar and nothing else")
        }

        let app = try backgroundLaunchedCalculator()
        let window = try XCTUnwrap(try windowOf(pid: app.pid), "Calculator came up with no window to observe")
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        XCTAssertNotEqual(
            frontBefore,
            app.pid,
            "Calculator is in the foreground, so nothing below could show that a background menu works"
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

        // MARK: The menu is there at all

        let started = Date()
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":3,"method":"observe","params":{"session":"s1","target":{"kind":"window","appId":"\#(window.appId)","pid":\#(window.pid),"processGeneration":"\#(hostProcessGeneration(hostProcessStartTime(pid: window.pid) ?? 0))","windowId":\#(window.windowId)},"includeImage":false,"menu":{"scope":"all"}}}
        """#)
        let observed = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])
        let observeMs = Date().timeIntervalSince(started) * 1000
        guard observed["ok"] as? Bool == true else {
            return XCTFail("observe: \((observed["error"] as? [String: Any])?["code"] ?? "?")")
        }

        let snapshot = try XCTUnwrap(observed["snapshot"] as? [String: Any])
        let snapshotId = try XCTUnwrap(snapshot["snapshotId"] as? String)
        let menu = try XCTUnwrap(snapshot["menu"] as? [String: Any], "`menu: true` produced no menu")
        let menuElements = try XCTUnwrap(menu["elements"] as? [[String: Any]])
        let windowElements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])

        print("""
          observe with menu: \(windowElements.count) window elements, \
        \(menuElements.count) menu elements, \(Int(observeMs)) ms
        """)

        XCTAssertGreaterThan(
            menuElements.count,
            20,
            "a real menu bar is hundreds of elements; this executor used to return zero of them"
        )
        XCTAssertEqual(menuElements.first?["role"] as? String, "AXMenuBar", "the menu observation is rooted at the menu bar")
        XCTAssertNil(menuElements.first?["parentToken"] as? String)
        XCTAssertTrue(
            menuElements.contains { $0["role"] as? String == "AXMenuItem" },
            "the walk descended past the bar into the menus"
        )
        XCTAssertTrue(
            menuElements.contains { ($0["actions"] as? [String])?.contains("press") == true },
            "menu items expose `press`, which is why no new dispatch kind was needed"
        )

        // MARK: Scope — the Apple menu is the system's

        XCTAssertFalse(
            menuElements.contains { $0["title"] as? String == "Apple" },
            "the Apple menu is out of scope (§5.8): it is identical under every app and it is where 关机 lives"
        )

        // MARK: Vector 62 — no frames, and none of them in `elements`

        let framed = menuElements.filter { $0["frame"] != nil && !($0["frame"] is NSNull) }
        XCTAssertTrue(
            framed.isEmpty,
            "\(framed.count) menu elements carried a frame; an unopened item's is the degenerate (0, 982, 0, 0) and a bar item's is screen space, and §5.3 declares this field window-local"
        )
        XCTAssertFalse(
            windowElements.contains { ($0["role"] as? String)?.hasPrefix("AXMenu") == true },
            "menu elements belong to `menu`, not to `elements`"
        )

        // MARK: Every menu element's binding, not just the one that gets pressed

        // The press below goes through `显示 > 基础`, whose parent is an `AXMenu`.
        // A top-level bar item's parent is the `AXMenuBar`, and that is the one
        // place the walk drops a child (the Apple menu) — so it is the one place
        // the walk's numbering and the probe's could disagree. They did: the walk
        // filtered before indexing and `siblingIndex` did not, so every bar item
        // recorded an index one below what dispatch recomputed, and every press
        // on 文件 / 编辑 / 显示 was refused `element_changed` with
        // `changed: ["siblingIndex"]` in the same second it was observed. The
        // press below never saw it, because a submenu item has no Apple menu
        // among its siblings.
        //
        // Recomputing is a read: nothing here presses anything, so it can cover
        // all of them, including the items pressing would be destructive.
        let environment = HostLiveEnvironment()
        if let menuRoot = environment.menuBarNode(pid: app.pid) {
            let walk = hostWalkTree(
                root: menuRoot,
                pid: app.pid,
                processStartTime: hostProcessStartTime(pid: app.pid) ?? 0,
                tokenPrefix: "seam_menu",
                bounds: HostTreeWalkBounds(
                    maxElements: 2000,
                    maxDepth: 24,
                    maxTextChars: 2000,
                    deadline: Date().addingTimeInterval(20)
                ),
                isMenu: true
            )
            let probe = HostAXBindingProbe(windowBounds: .zero)
            var disagreed: [String] = []
            for binding in walk.bindings {
                guard let now = probe.currentDigestInput(binding) else { continue }
                let fields = hostChangedDigestFields(recorded: binding.digestInput, current: now)
                if !fields.isEmpty {
                    let name = binding.observed.label ?? binding.observed.title ?? binding.observed.role
                    let names = fields.map { $0.rawValue }.joined(separator: ",")
                    disagreed.append("\(name) [\(binding.observed.role)] → \(names)")
                }
            }
            XCTAssertEqual(
                disagreed,
                [],
                "\(disagreed.count) of \(walk.bindings.count) menu bindings disagree with what dispatch recomputes for them, so those elements are addressable in the observation and refuse every dispatch"
            )
            let barItems = walk.bindings.filter { $0.observed.role == "AXMenuBarItem" }
            XCTAssertGreaterThan(
                barItems.count,
                2,
                "the seam check has to actually reach top-level bar items, which are the ones that regressed"
            )
        }

        // MARK: Vector 62 — the binding check agrees with itself across the seam

        func sizeOfCalculatorWindow() -> CGSize? {
            HostWindowInventory.onScreenWindows()
                .first { $0.pid == app.pid && $0.windowId == window.windowId }?
                .bounds.size
        }

        let sizeAtStart = try XCTUnwrap(sizeOfCalculatorWindow())

        // Both modes are pressed, in order, rather than one. Pressing a single
        // one proves nothing about whether it landed: Calculator was already in
        // `基础` on the first run of this test, so an `AXPress` that did exactly
        // nothing and an `AXPress` that set the mode it was already in are the
        // same measurement. Pressing both means one of the two must move the
        // window whatever mode the user left it in, and the pair is its own undo.
        let basic = ["基础", "Basic"]
        let scientific = ["科学", "Scientific"]

        let afterBasic = try pressMode(
            server: server,
            inbox: inbox,
            id: 4,
            appId: window.appId,
            pid: window.pid,
            windowId: window.windowId,
            titles: basic,
            size: sizeOfCalculatorWindow
        )
        let afterScientific = try pressMode(
            server: server,
            inbox: inbox,
            id: 6,
            appId: window.appId,
            pid: window.pid,
            windowId: window.windowId,
            titles: scientific,
            size: sizeOfCalculatorWindow
        )

        print("""
          window at start \(describe(sizeAtStart)); after 显示 > 基础 \(describe(afterBasic)); \
        after 显示 > 科学 \(describe(afterScientific))
        """)

        XCTAssertNotEqual(
            afterBasic,
            afterScientific,
            "both presses reported ok and the window is the same size either way — an AXPress on an item the application will not run returns kAXErrorSuccess and does nothing, which is why §5.8 keeps the element_disabled guard"
        )

        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
            frontBefore,
            "reading a menu and pressing a menu item must not put the application in front"
        )

        // MARK: Put it back

        if sizeOfCalculatorWindow() != sizeAtStart {
            _ = try? pressMode(
                server: server,
                inbox: inbox,
                id: 8,
                appId: window.appId,
                pid: window.pid,
                windowId: window.windowId,
                titles: sizeAtStart == afterBasic ? basic : scientific,
                size: sizeOfCalculatorWindow
            )
        }
        print("  restored: window is \(describe(sizeOfCalculatorWindow() ?? .zero)), started \(describe(sizeAtStart))")

        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
            frontBefore,
            "and neither must putting it back"
        )

        server.handle(line: #"{"jsonrpc":"2.0","id":99,"method":"session.end","params":{"session":"s1"}}"#)
        _ = try inbox.next()
    }

    // MARK: - Helpers

    private func describe(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    /// Observes the menu, presses the named mode item, and answers with the size
    /// the window settled at.
    ///
    /// A fresh `observe` per press because a mutating dispatch spends the frame
    /// it quoted (§4.1) — which is the rule under test as much as anything else
    /// here: the second press has to go through a second snapshot, and its menu
    /// tokens are a second set.
    @discardableResult
    /// §6.5 — a refused action reports the path it took, and it took none.
    ///
    ///     OPEN_COMPUTER_USE_RUN_MENU_LIVE_TEST=1 \
    ///         swift test --filter testARefusedActionSaysNothingWasDispatched
    ///
    /// Calculator advertises `AXRaise` on its window and answers -25205 when it
    /// is performed. That combination cannot be built from a fixture: a fake
    /// element fails with `invalidUIElement`, which is a different arm.
    ///
    /// What it cost, measured across 30 real model runs: `raise` was 36 of 217
    /// calls and 29 of them failed. 15 were this refusal, and because it claimed
    /// `path: "ax_action"` the host spent the frame — so each one also produced
    /// a `reobserve_required` on the next call and an `observe` after that. One
    /// refused action, three calls, 15-20% of everything the models did.
    func testARefusedActionSaysNothingWasDispatched() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_MENU_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_MENU_LIVE_TEST=1 to run this live test")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not granted to the process running these tests")
        }
        guard !hostScreenIsLocked() else {
            throw XCTSkip("The screen is locked")
        }

        let app = try backgroundLaunchedCalculator()
        let window = try XCTUnwrap(try windowOf(pid: app.pid), "Calculator came up with no window")
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

        server.handle(line: #"""
        {"jsonrpc":"2.0","id":3,"method":"observe","params":{"session":"s1","target":{"kind":"window","appId":"\#(window.appId)","pid":\#(window.pid),"processGeneration":"\#(hostProcessGeneration(hostProcessStartTime(pid: window.pid) ?? 0))","windowId":\#(window.windowId)},"includeImage":false}}
        """#)
        let observed = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])
        let snapshot = try XCTUnwrap(observed["snapshot"] as? [String: Any])
        let snapshotId = try XCTUnwrap(snapshot["snapshotId"] as? String)
        let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])

        let root = try XCTUnwrap(elements.first, "the walk always emits its root")
        try XCTSkipUnless(
            (root["actions"] as? [String])?.contains("raise") == true,
            "this window does not advertise raise, so there is nothing to refuse"
        )

        server.handle(line: #"""
        {"jsonrpc":"2.0","id":4,"method":"dispatch.element","params":{"session":"s1","snapshotId":"\#(snapshotId)","toolCallId":"call_4","elementToken":"\#(try XCTUnwrap(root["token"] as? String))","expectElementDigest":"\#(try XCTUnwrap(root["digest"] as? String))","action":{"kind":"secondary_action","action":"raise"}}}
        """#)
        let result = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])

        print("  raise on pid \(app.pid): ok=\(result["ok"] ?? "?") path=\(result["path"] ?? "?") error=\((result["error"] as? [String: Any])?["code"] ?? "-")")

        // Either answer is legitimate — TextEdit and Finder accept the same
        // action — so this asserts the pairing rather than the verdict.
        if result["ok"] as? Bool == false {
            XCTAssertEqual(
                (result["error"] as? [String: Any])?["code"] as? String,
                "dispatch_refused",
                "an advertised action the application rejects is a refusal, not a protocol error"
            )
            XCTAssertEqual(
                result["path"] as? String,
                "none",
                "AXUIElementPerformAction returned an error, so nothing reached the target and the host must not spend the frame"
            )
        } else {
            XCTAssertEqual(result["path"] as? String, "ax_action")
        }
    }

    private func pressMode(
        server: HostProtocolServer,
        inbox: ResponseInbox,
        id: Int,
        appId: String,
        pid: pid_t,
        windowId: CGWindowID,
        titles: [String],
        size: () -> CGSize?
    ) throws -> CGSize {
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":\#(id),"method":"observe","params":{"session":"s1","target":{"kind":"window","appId":"\#(appId)","pid":\#(pid),"processGeneration":"\#(hostProcessGeneration(hostProcessStartTime(pid: pid) ?? 0))","windowId":\#(windowId)},"includeImage":false,"menu":{"scope":"all"}}}
        """#)
        let observed = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])
        let snapshot = try XCTUnwrap(observed["snapshot"] as? [String: Any])
        let snapshotId = try XCTUnwrap(snapshot["snapshotId"] as? String)
        let elements = try XCTUnwrap((snapshot["menu"] as? [String: Any])?["elements"] as? [[String: Any]])

        let item = try XCTUnwrap(
            elements.first {
                $0["enabled"] as? Bool == true
                    && ($0["actions"] as? [String])?.contains("press") == true
                    && titles.contains(($0["title"] as? String) ?? "")
            },
            "no enabled, pressable menu item titled one of \(titles)"
        )

        let before = size()
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":\#(id + 1),"method":"dispatch.element","params":{"session":"s1","snapshotId":"\#(snapshotId)","toolCallId":"call_\#(id)","elementToken":"\#(try XCTUnwrap(item["token"] as? String))","expectElementDigest":"\#(try XCTUnwrap(item["digest"] as? String))","action":{"kind":"click","button":"left","count":1}}}
        """#)
        let pressed = try XCTUnwrap(try inbox.next(timeout: 30)["result"] as? [String: Any])

        XCTAssertNotEqual(
            (pressed["error"] as? [String: Any])?["code"] as? String,
            "element_changed",
            """
            nothing moved between the observation and the dispatch, so the binding must still hold. \
            `changed: ["frame"]` here means the walk suppressed the frame and the probe recomputed it: \
            \(String(describing: (pressed["error"] as? [String: Any])?["detail"]))
            """
        )
        XCTAssertEqual(pressed["ok"] as? Bool, true, "\(pressed)")
        XCTAssertEqual(pressed["outcome"] as? String, "ok")
        XCTAssertEqual(pressed["path"] as? String, "ax_action", "a menu item is pressed, never clicked at a pixel")
        XCTAssertEqual(pressed["tier"] as? String, "ax")

        // The window server catches up after the application acknowledges, so
        // the size is polled rather than read once.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let now = size(), now != before {
                return now
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        return try XCTUnwrap(size())
    }

    /// Calculator, running, without having taken the foreground to get there. It
    /// is left running: quitting an application the user may have opened is a
    /// side effect a test has no business having.
    private func backgroundLaunchedCalculator() throws -> RunningAppDescriptor {
        guard FileManager.default.fileExists(atPath: "/System/Applications/Calculator.app") else {
            throw XCTSkip("Calculator is not installed")
        }

        let resolved = Outcome()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            resolved.result = Result { try AppDiscovery.resolve("Calculator", waitFor: 20) }
            finished.signal()
        }

        guard finished.wait(timeout: .now() + 40) == .success else {
            throw ComputerUseError.message("Calculator never resolved")
        }
        return try XCTUnwrap(resolved.result).get()
    }

    /// Its on-screen ordinary window, waited for: a launch returns before the
    /// window is mapped, measured at 1.3–3.2 s against 2.3–4.5 s (§5.7).
    private func windowOf(pid: pid_t) throws -> HostWindowInfo? {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let windows = HostWindowInventory.onScreenWindows()
                .filter { $0.pid == pid && $0.layer == 0 && $0.bounds.width > 64 && $0.bounds.height > 64 }
            if let first = windows.first {
                return first
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        return nil
    }

    private func makeImageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-menu-live-\(UUID().uuidString)", isDirectory: true)
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
