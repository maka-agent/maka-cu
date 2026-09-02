import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// `observe`, naming, hashes and file lifetime (§1.3, §5.1, §5.2, §8, §11).
final class HostObserveContractTests: XCTestCase {
    // MARK: - `observe` is a read (§5.2)

    func testWindowIdentitySelectsOnlyOneExactWindowIdAndMatchingFrame() {
        let target = CGRect(x: 100, y: 100, width: 360, height: 150)
        XCTAssertEqual(
            hostUniqueWindowCandidate(
                [
                    (element: "same-frame-wrong-id", windowId: 40, frame: target),
                    (element: "sheet", windowId: 41, frame: CGRect(x: 100.4, y: 99.6, width: 360, height: 150)),
                ],
                matching: 41,
                bounds: target
            ),
            "sheet"
        )
        XCTAssertNil(
            hostUniqueWindowCandidate(
                [
                    (element: "first", windowId: 41, frame: target),
                    (element: "second", windowId: 41, frame: target),
                ],
                matching: 41,
                bounds: target
            ),
            "duplicate AX candidates for one CGWindowID must fail closed"
        )
        XCTAssertNil(
            hostUniqueWindowCandidate(
                [(element: "moved", windowId: 41, frame: CGRect(x: 101, y: 100, width: 360, height: 150))],
                matching: 41,
                bounds: target
            )
        )
    }

    func testSecondObservationCarriesNoChangeDifferenceAgainstFirstSnapshot() throws {
        let pid = getpid()
        let appId = "pid:\(pid)"
        var environment = FakeEnvironment()
        environment.apps = [
            HostRunningApp(appId: appId, pid: pid, name: "Fixture", running: true),
        ]
        environment.windows = [
            hostTestWindow(
                windowId: 81,
                pid: pid,
                appId: appId,
                bounds: CGRect(x: 50, y: 50, width: 800, height: 600),
                title: "Stable",
                zIndex: 3
            ),
        ]
        environment.windowElement = hostTestElement(pid: pid)

        let harness = ServerHarness(environment: environment)
        try harness.begin()

        harness.send(observe(appId: appId, pid: pid, windowId: 81))
        let first = try XCTUnwrap(
            try harness.awaitResult()["snapshot"] as? [String: Any]
        )
        XCTAssertNil(first["difference"])
        let firstId = try XCTUnwrap(first["snapshotId"] as? String)

        harness.send(observe(appId: appId, pid: pid, windowId: 81))
        let second = try XCTUnwrap(
            try harness.awaitResult()["snapshot"] as? [String: Any]
        )
        let difference = try XCTUnwrap(second["difference"] as? [String: Any])
        XCTAssertEqual(difference["baseSnapshotId"] as? String, firstId)
        XCTAssertEqual(difference["presentation"] as? String, "no-change")
        XCTAssertEqual((difference["changes"] as? [[String: Any]])?.count, 0)
    }

    func testObserveWaitsForANewWindowsAccessibilityElement() throws {
        let pid = getpid()
        let appId = "pid:\(pid)"
        var environment = FakeEnvironment()
        environment.apps = [
            HostRunningApp(appId: appId, pid: pid, name: "Fixture", running: true),
        ]
        environment.windows = [
            hostTestWindow(windowId: 91, pid: pid, appId: appId),
        ]
        environment.windowElements.sequence = [
            nil,
            hostTestElement(pid: pid),
        ]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        harness.send(observe(appId: appId, pid: pid, windowId: 91))

        let snapshot = try XCTUnwrap(
            try harness.awaitResult()["snapshot"] as? [String: Any]
        )
        XCTAssertEqual(
            (snapshot["target"] as? [String: Any])?["windowId"] as? UInt32,
            91
        )
        XCTAssertEqual(harness.environment.windowElements.reads, 2)
    }

    func testObserveRefusalsDoNotCarryTheDispatchFields() throws {
        // §1.1 — no other method's `ok: false` arm carries them: `observe`
        // dispatched nothing, so an `outcome` on it would be a field with no
        // producer.
        var environment = FakeEnvironment()
        environment.windows = []

        let harness = ServerHarness(environment: environment)
        try harness.begin()

        harness.send(observe(appId: "com.example.absent", pid: hostTestPid, windowId: 999))
        let result = try harness.awaitResult()
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertNil(result["outcome"])
        XCTAssertNil(result["path"])
        XCTAssertNil(result["tier"])
    }

    // MARK: - One namespace (§5.1)

    func testOneProcessIsSpelledTheSameWayEverywhereItIsNamed() throws {
        // Vector 30. `window.list`, `snapshot.target` and `apps.list` all report
        // the string `hostAppId` produced for the process, and there is no
        // `bundleId` beside it — a second spelling is what §5.1 removes.
        var environment = FakeEnvironment()
        environment.apps = [
            HostRunningApp(appId: hostTestAppId, pid: hostTestPid, name: "Notes", running: true),
        ]
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()

        harness.send(#"{"jsonrpc":"2.0","id":10,"method":"window.list","params":{"session":"s1"}}"#)
        let windows = try XCTUnwrap(try harness.awaitResult()["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.first?["appId"] as? String, hostTestAppId)
        XCTAssertNil(windows.first?["bundleId"])

        harness.send(#"{"jsonrpc":"2.0","id":11,"method":"apps.list","params":{"session":"s1"}}"#)
        let apps = try XCTUnwrap(try harness.awaitResult()["apps"] as? [[String: Any]])
        XCTAssertEqual(apps.first?["appId"] as? String, hostTestAppId)
        XCTAssertNil(apps.first?["bundleId"])

        let snapshot = hostTestSnapshot(registry: harness.server.currentRegistry(), session: "s1")
        let encoded = try JSONSerialization.jsonObject(
            with: try HostProtocolCodec.encoder.encode(snapshot.payload)
        ) as? [String: Any]
        let target = try XCTUnwrap((encoded?["target"]) as? [String: Any])
        XCTAssertEqual(target["appId"] as? String, hostTestAppId)
        XCTAssertNil(target["bundleId"])
    }

    func testAProcessWithNoBundleIdentifierIsNamedByItsPid() {
        XCTAssertEqual(hostAppId(bundleIdentifier: "com.apple.Notes", pid: 4711), "com.apple.Notes")
        XCTAssertEqual(hostAppId(bundleIdentifier: nil, pid: 4711), "pid:4711")
        XCTAssertEqual(hostAppId(bundleIdentifier: "", pid: 4711), "pid:4711")
    }

    // MARK: - One way to write a hash (§1.3)

    func testEveryHashInOneResponseIsPrefixedLowercaseHex() throws {
        // Vector 28. The host computes its own digest and prefixes it before
        // comparing; a bare-hex value here is what made every screenshot
        // mismatch, and a mismatched image is teardown.
        let pattern = try NSRegularExpression(pattern: "^sha256:[0-9a-f]{64}$")
        func isCanonical(_ value: String) -> Bool {
            pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }

        let registry = HostSnapshotRegistry(limits: HostLimits(), processNonce: "nonce-hash") { _ in }
        try registry.beginSession("s1", captureScope: .window)
        let snapshot = hostTestSnapshot(registry: registry, session: "s1")

        XCTAssertTrue(isCanonical(snapshot.windowDigest), snapshot.windowDigest)
        XCTAssertTrue(isCanonical(snapshot.payload.elements[0].digest))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostImageStore(directory: directory, budgetBytes: 1 << 20)
        let written = store.writePNG(try makeImage(), namePrefix: "snap", logicalWidth: 2)
        let reference = try XCTUnwrap(try? written.get())
        XCTAssertTrue(isCanonical(reference.sha256), reference.sha256)
    }

    // MARK: - Image lifetime (§8)

    func testScreenCaptureImagesExpireOnTheSnapshotClockAndAtSessionEnd() throws {
        // `screen.capture` images are attached to no snapshot, so nothing retired
        // them: they accumulated in `imageDir` for the life of the process, and
        // only the directory budget stood between a long session and a full disk.
        var deleted: [String] = []
        let limits = HostLimits()
        let registry = HostSnapshotRegistry(limits: limits, processNonce: "nonce-cap") { deleted.append($0) }
        try registry.beginSession("s1", captureScope: .window)

        registry.registerUnattachedImage(session: "s1", path: "/tmp/cap_old.png", capturedAt: 0)
        registry.registerUnattachedImage(session: "s1", path: "/tmp/cap_new.png", capturedAt: Int64(limits.snapshotTtlMs))

        XCTAssertEqual(registry.sweepUnattachedImages(now: Int64(limits.snapshotTtlMs)), 1)
        XCTAssertEqual(deleted, ["/tmp/cap_old.png"])

        // §3 — teardown deletes every image file the session produced, and the
        // count is what the host asserts on.
        let released = registry.endSession("s1")
        XCTAssertEqual(released.images, 1)
        XCTAssertEqual(deleted, ["/tmp/cap_old.png", "/tmp/cap_new.png"])
    }

    // MARK: - Capture scope (§5.3)

    func testDesktopScopeCapturesTheWindowRectangleAndNotADisplayOriginCrop() {
        // A whole-display filter sized to the window produced a display-origin
        // crop while `image.scale` and `image_px` both anchor at the window's
        // origin, so the returned pixels did not describe the declared window.
        let rect = hostDesktopSourceRect(
            windowFrame: CGRect(x: 1512, y: 200, width: 800, height: 600),
            displayFrame: CGRect(x: 1512, y: 0, width: 1512, height: 982)
        )

        XCTAssertEqual(rect, CGRect(x: 0, y: 200, width: 800, height: 600))

        let onPrimary = hostDesktopSourceRect(
            windowFrame: CGRect(x: 40, y: 25, width: 300, height: 200),
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
        XCTAssertEqual(onPrimary, CGRect(x: 40, y: 25, width: 300, height: 200))
    }

    // MARK: - Shutdown (§11)

    func testWorkQueuedButNotStartedIsAnsweredWhenShutdownBegins() {
        // §11 — SIGTERM stops new work; anything already on a lane has been read
        // and therefore owes exactly one response. Running it anyway ignores the
        // shutdown, and dropping it at the grace deadline leaves the id
        // unanswered.
        let scheduler = HostLaneScheduler()
        let observed = Observations()
        let blocked = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)

        scheduler.enqueue(.control, {
            started.signal()
            blocked.wait()
        })
        started.wait()

        scheduler.enqueue(.control, { observed.record("ran") }, ifShuttingDown: { observed.record("aborted") })
        scheduler.beginShutdown()
        blocked.signal()

        XCTAssertEqual(scheduler.waitForCompletion(timeout: .now() + .seconds(5)), .success)
        XCTAssertEqual(observed.entries, ["aborted"])
    }

    // MARK: - Helpers

    private final class Observations {
        private let lock = NSLock()
        private var storage: [String] = []

        func record(_ entry: String) {
            lock.lock()
            storage.append(entry)
            lock.unlock()
        }

        var entries: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private var nextId = 200

    private func observe(appId: String, pid: pid_t, windowId: CGWindowID) -> String {
        nextId += 1
        return """
        {"jsonrpc":"2.0","id":\(nextId),"method":"observe","params":{"session":"s1",\
        "target":{"kind":"window","appId":"\(appId)","pid":\(pid),\
        "processGeneration":"\(hostProcessGeneration(UInt64(pid)))","windowId":\(windowId)},\
        "includeImage":false}}
        """
    }

    private func errorCode(_ result: [String: Any]) throws -> String {
        try XCTUnwrap((result["error"] as? [String: Any])?["code"] as? String)
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try XCTUnwrap(context.makeImage())
    }
}
