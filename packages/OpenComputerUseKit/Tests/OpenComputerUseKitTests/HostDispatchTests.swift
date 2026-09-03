import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// The dispatch handlers, end to end over the wire (§6, §12 vectors 5–8, 10, 14,
/// 25–27).
///
/// `maka.cu/1` shipped with none of this: `dispatch.element`, `dispatch.point`
/// and `dispatch.key` were never sent in a test, so deleting the echoed-digest
/// comparison, the binding probe, the occlusion gate or the `spend()` call left
/// every test green. The binding is the reason this protocol exists; these are
/// the tests that turn red when it goes.
final class HostDispatchTests: XCTestCase {
    func testOnlySinglePressLikeActionsMayConfirmByChangingWindowTopology() {
        XCTAssertTrue(hostUnknownActionMayChangeWindowTopology(.click(button: .left, count: 1)))
        XCTAssertTrue(hostUnknownActionMayChangeWindowTopology(.secondaryAction(.press)))
        XCTAssertTrue(hostUnknownActionMayChangeWindowTopology(.secondaryAction(.cancel)))

        XCTAssertFalse(hostUnknownActionMayChangeWindowTopology(.click(button: .left, count: 2)))
        XCTAssertFalse(hostUnknownActionMayChangeWindowTopology(.click(button: .right, count: 1)))
        XCTAssertFalse(hostUnknownActionMayChangeWindowTopology(.setValue("x")))
        XCTAssertFalse(hostUnknownActionMayChangeWindowTopology(.scroll(direction: .down, pages: 1)))
    }

    func testForegroundRestoreOnlyTargetsThePreviousAppAfterTargetActivation() {
        XCTAssertEqual(
            hostForegroundPidToRestore(previousPid: 41, currentPid: 52, targetPid: 52),
            41
        )
        XCTAssertNil(
            hostForegroundPidToRestore(previousPid: 41, currentPid: 63, targetPid: 52),
            "a user switch to a third app must not be overwritten"
        )
        XCTAssertNil(
            hostForegroundPidToRestore(previousPid: 52, currentPid: 52, targetPid: 52),
            "an already-frontmost target has no prior foreground to restore"
        )
        XCTAssertNil(hostForegroundPidToRestore(previousPid: nil, currentPid: 52, targetPid: 52))
    }

    // MARK: - The four declared fields on the refusal arm (§1.1, §6.5)

    func testEveryRefusalCarriesTheFourDeclaredFieldsAndTheirFixedPairing() throws {
        // A binding refusal, a policy refusal and a snapshot-state refusal all
        // answer on the same arm. A host that requires them rejects a refusal
        // that arrives with `error` and nothing else, which is what the executor
        // used to send.
        for (probe, occlusion, expected) in [
            (FakeBindingProbe(override: HostElementDigestInput(role: "AXButton", label: "Sent")), "none", "element_changed"),
            (FakeBindingProbe(), "any", "window_occluded"),
        ] {
            var environment = FakeEnvironment()
            environment.probe = probe
            environment.windows = [
                hostTestWindow(),
                hostTestWindow(windowId: 2, pid: 9999, appId: "pid:9999", zIndex: 9),
            ]

            let harness = ServerHarness(environment: environment)
            try harness.begin()
            let snapshot = hostTestSnapshot(
                registry: harness.server.currentRegistry(),
                session: "s1",
                elementFrame: HostRect(x: 10, y: 10, width: 20, height: 20)
            )
            harness.install(snapshot)

            harness.send(dispatchElement(snapshot: snapshot, occlusionPolicy: occlusion))
            let result = try harness.awaitResult()

            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(result["toolCallId"] as? String, "call_1")
            XCTAssertEqual(result["outcome"] as? String, "refused")
            XCTAssertEqual(result["tier"] as? String, "ax", "a refusal reports the tier it would have used")
            XCTAssertEqual(result["path"] as? String, "none", "nothing was dispatched")
            XCTAssertEqual(result["effect"] as? String, "unverifiable")
            let verification = try XCTUnwrap(result["verification"] as? [String: Any])
            XCTAssertEqual(verification["method"] as? String, "none")
            XCTAssertEqual(verification["observedChange"] as? Bool, false)
            XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, expected)
        }
    }

    func testARefusalLeavesTheQuotedFrameLive() throws {
        var environment = FakeEnvironment()
        environment.probe = FakeBindingProbe(override: HostElementDigestInput(role: "AXButton", label: "Sent"))
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(registry: harness.server.currentRegistry(), session: "s1")
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))
        _ = try harness.awaitResult()

        // §4.1 — the host may fix the argument and retry against the same frame.
        XCTAssertEqual(
            harness.server.currentRegistry().snapshotState(session: "s1", snapshotId: snapshot.id),
            .live
        )
    }

    func testElementReparentedToAnotherWindowIsRefusedBeforeAnyEffect() throws {
        var environment = FakeEnvironment()
        var probe = FakeBindingProbe()
        probe.belongsToTarget = false
        environment.probe = probe
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(registry: harness.server.currentRegistry(), session: "s1")
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))

        XCTAssertEqual(try errorCode(harness.awaitResult()), "window_changed")
        XCTAssertTrue(harness.environment.pointEvents.posted.isEmpty)
    }

    func testRepeatedActionStopsWhenTheApprovedTargetChangesAfterTheFirstEffect() throws {
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]
        environment.probe = ActionReactiveBindingProbe(actions: environment.accessibilityActions)

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: hostTestElement(),
            elementActions: [.press]
        )
        harness.install(snapshot)

        harness.send(
            dispatchElement(
                snapshot: snapshot,
                action: #"{"kind":"click","button":"left","count":2}"#
            )
        )
        let result = try harness.awaitResult()

        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["outcome"] as? String, "unknown")
        XCTAssertEqual(try errorCode(result), "outcome_unknown")
        XCTAssertEqual(harness.environment.accessibilityActions.performed, [.press])
        XCTAssertEqual(
            harness.server.currentRegistry().snapshotState(session: "s1", snapshotId: snapshot.id),
            .spent,
            "the first effect landed before the target changed"
        )
    }

    func testPostObservationRootLossDoesNotEraseAKnownSuccessfulEffect() throws {
        let harness = ServerHarness()
        try harness.begin()
        let snapshot = hostTestSnapshot(registry: harness.server.currentRegistry(), session: "s1")
        harness.install(snapshot)

        harness.server.finishDispatch(
            id: 81,
            toolCallId: "call_1",
            snapshot: snapshot,
            outcome: .ok,
            path: .axAttribute,
            verificationIsTreeDelta: false,
            fallbackVerdict: HostEffectVerdict(
                effect: .confirmed,
                verification: HostVerification(method: .valueReadback, observedChange: true)
            ),
            settleMode: .none,
            observeAfter: HostObserveAfter(includeImage: false, settle: .none, menu: nil),
            applicationLevel: false,
            window: hostTestWindow()
        )
        let result = try harness.awaitResult()

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["outcome"] as? String, "ok")
        XCTAssertEqual(result["path"] as? String, "ax_attribute")
        XCTAssertEqual(result["effect"] as? String, "confirmed")
        XCTAssertEqual(
            (result["postObservationError"] as? [String: Any])?["code"] as? String,
            "window_gone"
        )
    }

    func testMenuBindingUsesApplicationIdentityWhenItsSnapshotWindowIsGone() throws {
        var environment = FakeEnvironment()
        environment.apps = [
            HostRunningApp(appId: hostTestAppId, pid: hostTestPid, name: "Notes", running: true),
        ]
        environment.windows = []

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            enabled: false,
            isMenu: true
        )
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))

        XCTAssertEqual(try errorCode(harness.awaitResult()), "element_disabled")
    }

    // MARK: - Element binding (§4.3, §6.2)

    func testTheEchoedDigestSeparatesAnUnknownTokenFromAMismatchedEcho() throws {
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(registry: harness.server.currentRegistry(), session: "s1")
        harness.install(snapshot)
        let token = snapshot.payload.elements[0].token
        let digest = snapshot.payload.elements[0].digest

        // A token this snapshot never minted: the host quoted the wrong frame.
        harness.send(dispatchElement(snapshot: snapshot, token: "el_not_from_here", digest: digest))
        XCTAssertEqual(try errorCode(harness.awaitResult()), "element_unknown")

        // A token it did mint, carrying an echo it never recorded: the host
        // paired a token from one snapshot with a digest from another. §6.2 —
        // folding this into `element_unknown` told the host "stale frame", so it
        // re-observed and echoed the same wrong digest again.
        harness.send(dispatchElement(snapshot: snapshot, token: token, digest: "sha256:" + String(repeating: "b", count: 64)))
        XCTAssertEqual(try errorCode(harness.awaitResult()), "element_digest_mismatch")
    }

    func testDeletingTheBindingCheckWouldLetADeadOrChangedElementThrough() throws {
        // Vector 5. Each row names one of E1–E3 and the code only the binding
        // check can produce.
        var released = FakeBindingProbe()
        released.alive = false

        var replaced = FakeBindingProbe()
        replaced.startTime = hostTestProcessStartTime + 1

        let changed = FakeBindingProbe(override: HostElementDigestInput(role: "AXButton", label: "Sent"))

        for (probe, expected) in [
            (released, "element_released"),
            (replaced, "process_replaced"),
            (changed, "element_changed"),
        ] {
            var environment = FakeEnvironment()
            environment.probe = probe
            environment.windows = [hostTestWindow()]

            let harness = ServerHarness(environment: environment)
            try harness.begin()
            let snapshot = hostTestSnapshot(registry: harness.server.currentRegistry(), session: "s1")
            harness.install(snapshot)

            harness.send(dispatchElement(snapshot: snapshot))
            let result = try harness.awaitResult()
            XCTAssertEqual(try errorCode(result), expected)

            if expected == "element_changed" {
                let detail = try XCTUnwrap((result["error"] as? [String: Any])?["detail"] as? [String: Any])
                XCTAssertEqual(detail["changed"] as? [String], ["label"])
            }
        }
    }

    func testAReleasedReferenceUsesOnlyAUniqueIdentityPreservingRefetch() throws {
        let digestInput = HostElementDigestInput(role: "AXButton", label: "Send")
        let replacement = hostTestBinding(
            token: "replacement",
            digestInput: digestInput,
            enabled: false,
            element: hostTestElement()
        )

        var probe = FakeBindingProbe()
        probe.alive = false
        probe.refetch = .unique(replacement)

        var environment = FakeEnvironment()
        environment.probe = probe
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: hostTestElement()
        )
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))
        XCTAssertEqual(
            try errorCode(harness.awaitResult()),
            "element_disabled",
            "the unique replacement was used; the dead retained reference was not"
        )
    }

    func testADirectWebContentFrameOnlyReflowUsesTheTrustedRefetchedTarget() throws {
        let oldFrame = HostRect(x: 20, y: 30, width: 120, height: 40)
        let movedFrame = HostRect(x: 24, y: 34, width: 120, height: 40)
        let webContentPid = hostTestPid + 1
        let webContentStartTime = hostTestProcessStartTime + 10
        let replacement = hostTestBinding(
            token: "replacement",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                label: "Send",
                frameInWindow: movedFrame.cgRect
            ),
            frame: movedFrame,
            element: hostTestElement(pid: webContentPid),
            dispatchPid: webContentPid,
            dispatchProcessStartTime: webContentStartTime
        )

        var probe = FakeBindingProbe(
            override: HostElementDigestInput(
                role: "AXButton",
                label: "Send",
                frameInWindow: movedFrame.cgRect
            )
        )
        probe.refetch = .unique(replacement)
        probe.startTimes = [
            hostTestPid: hostTestProcessStartTime,
            webContentPid: webContentStartTime,
        ]

        var environment = FakeEnvironment()
        environment.probe = probe
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            elementFrame: oldFrame,
            element: hostTestElement(pid: webContentPid),
            dispatchPid: webContentPid,
            dispatchProcessStartTime: webContentStartTime
        )
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))
        let result = try harness.awaitResult()
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["outcome"] as? String, "ok")
        XCTAssertEqual(result["path"] as? String, "skylight_pid")
        XCTAssertEqual(harness.environment.pointEvents.posted.count, 1)
        XCTAssertEqual(harness.environment.pointEvents.posted.first?.pid, webContentPid)
    }

    func testADirectWebContentFrameOnlyReflowFailsClosedWithoutOneReplacement() throws {
        let oldFrame = HostRect(x: 20, y: 30, width: 120, height: 40)
        let movedFrame = HostRect(x: 24, y: 34, width: 120, height: 40)
        let webContentPid = hostTestPid + 1
        let webContentStartTime = hostTestProcessStartTime + 10

        for refetch in [HostBindingRefetchResult.missing, .ambiguous] {
            var probe = FakeBindingProbe(
                override: HostElementDigestInput(
                    role: "AXButton",
                    label: "Send",
                    frameInWindow: movedFrame.cgRect
                )
            )
            probe.refetch = refetch
            probe.startTimes = [
                hostTestPid: hostTestProcessStartTime,
                webContentPid: webContentStartTime,
            ]

            var environment = FakeEnvironment()
            environment.probe = probe
            environment.windows = [hostTestWindow()]

            let harness = ServerHarness(environment: environment)
            try harness.begin()
            let snapshot = hostTestSnapshot(
                registry: harness.server.currentRegistry(),
                session: "s1",
                elementFrame: oldFrame,
                element: hostTestElement(pid: webContentPid),
                dispatchPid: webContentPid,
                dispatchProcessStartTime: webContentStartTime
            )
            harness.install(snapshot)

            harness.send(dispatchElement(snapshot: snapshot))
            XCTAssertEqual(try errorCode(harness.awaitResult()), "element_changed")
            XCTAssertTrue(harness.environment.pointEvents.posted.isEmpty)
        }
    }

    func testANativeFrameOnlyChangeStillFailsClosed() throws {
        let oldFrame = HostRect(x: 20, y: 30, width: 120, height: 40)
        let movedFrame = HostRect(x: 24, y: 34, width: 120, height: 40)
        var probe = FakeBindingProbe(
            override: HostElementDigestInput(
                role: "AXButton",
                label: "Send",
                frameInWindow: movedFrame.cgRect
            )
        )
        probe.refetch = .unique(
            hostTestBinding(
                token: "replacement",
                digestInput: HostElementDigestInput(
                    role: "AXButton",
                    label: "Send",
                    frameInWindow: movedFrame.cgRect
                ),
                frame: movedFrame,
                element: hostTestElement()
            )
        )

        var environment = FakeEnvironment()
        environment.probe = probe
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            elementFrame: oldFrame,
            element: hostTestElement()
        )
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))
        XCTAssertEqual(try errorCode(harness.awaitResult()), "element_changed")
        XCTAssertTrue(harness.environment.pointEvents.posted.isEmpty)
    }

    func testAnAmbiguousRefetchFailsClosed() throws {
        var probe = FakeBindingProbe()
        probe.alive = false
        probe.refetch = .ambiguous

        var environment = FakeEnvironment()
        environment.probe = probe
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: hostTestElement()
        )
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))
        XCTAssertEqual(try errorCode(harness.awaitResult()), "element_changed")
        XCTAssertTrue(harness.environment.pointEvents.posted.isEmpty)
    }

    func testAUniqueWebContentEquivalentReplacesAHostMirror() throws {
        let frame = HostRect(x: 20, y: 30, width: 120, height: 40)
        let webContent = hostTestBinding(
            token: "web-content",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "submit",
                label: "Send",
                frameInWindow: frame.cgRect,
                actionNames: ["press"]
            ),
            enabled: false,
            frame: frame,
            element: hostTestElement(pid: hostTestPid + 1),
            dispatchPid: hostTestPid + 1
        )

        var probe = FakeBindingProbe()
        probe.webContentEquivalent = webContent

        var environment = FakeEnvironment()
        environment.probe = probe
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            elementFrame: frame,
            element: hostTestElement()
        )
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))
        XCTAssertEqual(
            try errorCode(harness.awaitResult()),
            "element_disabled",
            "dispatch used the renderer-owned equivalent"
        )
    }

    func testWebContentClickUsesHostWindowAndRendererPid() throws {
        let frame = HostRect(x: 20, y: 30, width: 120, height: 40)
        let webContent = hostTestBinding(
            token: "web-content",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "submit",
                label: "Send",
                frameInWindow: frame.cgRect,
                actionNames: ["press"],
                ancestorRoles: ["AXGroup", "AXWebArea"]
            ),
            frame: frame,
            element: hostTestElement(pid: hostTestPid + 1),
            dispatchPid: hostTestPid + 1
        )

        var probe = FakeBindingProbe()
        probe.webContentEquivalent = webContent

        var environment = FakeEnvironment()
        environment.probe = probe
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            elementFrame: frame,
            element: hostTestElement()
        )
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))
        let result = try harness.awaitResult()

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["path"] as? String, "skylight_pid")
        XCTAssertEqual(result["tier"] as? String, "coordinate-background")
        let posted = try XCTUnwrap(harness.environment.pointEvents.posted.first)
        XCTAssertEqual(posted.pid, hostTestPid + 1)
        XCTAssertEqual(posted.path, .skylightPid)
        XCTAssertEqual(posted.point, CGPoint(x: 80, y: 50))
    }

    func testWebContentEquivalenceRequiresIdentityGeometryAndUniquenessInputs() {
        let frame = HostRect(x: 20, y: 30, width: 120, height: 40)
        let recorded = hostTestBinding(
            token: "host",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "submit",
                label: "Send",
                frameInWindow: frame.cgRect,
                actionNames: ["press"]
            ),
            frame: frame
        )
        let renderer = hostTestBinding(
            token: "renderer",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "submit",
                label: "Send",
                frameInWindow: frame.cgRect,
                actionNames: ["press"]
            ),
            frame: frame,
            dispatchPid: hostTestPid + 1
        )
        let rendererBeforePidDiscovery = hostTestBinding(
            token: "renderer-delayed",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "submit",
                label: "Send",
                frameInWindow: frame.cgRect,
                actionNames: ["press"],
                ancestorRoles: ["AXGroup", "AXWebArea", "AXScrollArea"]
            ),
            frame: frame
        )
        let wrongFrame = hostTestBinding(
            token: "wrong",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "submit",
                label: "Send",
                frameInWindow: CGRect(x: 300, y: 30, width: 120, height: 40),
                actionNames: ["press"]
            ),
            frame: HostRect(x: 300, y: 30, width: 120, height: 40),
            dispatchPid: hostTestPid + 1
        )

        XCTAssertTrue(hostIsWebContentEquivalent(recorded: recorded, candidate: renderer))
        XCTAssertTrue(
            hostIsWebContentEquivalent(recorded: recorded, candidate: rendererBeforePidDiscovery)
        )
        XCTAssertFalse(hostIsWebContentEquivalent(recorded: recorded, candidate: wrongFrame))
    }

    func testObservationRemovesOnlyAUniqueLeafMirrorShadowedByWebContent() {
        let frame = HostRect(x: 20, y: 30, width: 120, height: 40)
        let mirror = hostTestBinding(
            token: "mirror",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "submit",
                label: "Send",
                frameInWindow: frame.cgRect,
                actionNames: ["press"]
            ),
            frame: frame
        )
        let webContent = hostTestBinding(
            token: "web",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "submit",
                label: "Send",
                frameInWindow: frame.cgRect,
                actionNames: ["press", "show_menu"],
                ancestorRoles: ["AXGroup", "AXWebArea"]
            ),
            frame: frame,
            actions: [.press, .showMenu],
            dispatchPid: hostTestPid + 1
        )
        let result = HostTreeWalkResult(
            elements: [mirror.observed, webContent.observed],
            bindings: [mirror, webContent],
            truncated: HostSnapshotTruncation(elements: false, depth: false),
            focusedToken: mirror.token
        )

        let filtered = hostRemovingShadowedWebMirrors(result)
        XCTAssertEqual(filtered.elements.map(\.token), [webContent.token])
        XCTAssertEqual(filtered.bindings.map(\.token), [webContent.token])
        XCTAssertEqual(filtered.focusedToken, webContent.token)
    }

    func testRefetchAllowsReflowButNeverCrossesProcessGenerationOrSemanticIdentity() {
        let recorded = hostTestBinding(
            token: "old",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "stable-target",
                label: "Send",
                frameInWindow: CGRect(x: 10, y: 10, width: 80, height: 30),
                actionNames: ["press"],
                siblingIndex: 2
            )
        )
        let moved = hostTestBinding(
            token: "new",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "stable-target",
                label: "Send",
                frameInWindow: CGRect(x: 200, y: 40, width: 80, height: 30),
                actionNames: ["press"],
                ancestorRoles: ["AXGroup", "AXWindow"],
                siblingIndex: 7
            )
        )
        let wrongIdentifier = hostTestBinding(
            token: "wrong",
            digestInput: HostElementDigestInput(
                role: "AXButton",
                axIdentifier: "different-target",
                label: "Send",
                actionNames: ["press"]
            )
        )
        let replacedRenderer = hostTestBinding(
            token: "renderer",
            digestInput: moved.digestInput,
            dispatchPid: hostTestPid + 1,
            dispatchProcessStartTime: hostTestProcessStartTime + 1
        )

        XCTAssertTrue(hostIsIdentityPreservingRefetch(recorded: recorded, candidate: moved))
        XCTAssertFalse(hostIsIdentityPreservingRefetch(recorded: recorded, candidate: wrongIdentifier))
        XCTAssertFalse(hostIsIdentityPreservingRefetch(recorded: recorded, candidate: replacedRenderer))
    }

    func testRendererPidAndStartTimeArePartOfTheBinding() {
        let binding = hostTestBinding(
            token: "web",
            digestInput: HostElementDigestInput(role: "AXButton", label: "Send"),
            dispatchPid: hostTestPid + 1,
            dispatchProcessStartTime: hostTestProcessStartTime + 10
        )

        var changedPid = FakeBindingProbe()
        changedPid.actualPidOverride = hostTestPid + 2
        XCTAssertEqual(hostVerifyBinding(binding, probe: changedPid)?.code, .processReplaced)

        var changedStart = FakeBindingProbe()
        changedStart.actualPidOverride = hostTestPid + 1
        changedStart.startTimes = [
            hostTestPid: hostTestProcessStartTime,
            hostTestPid + 1: hostTestProcessStartTime + 11,
        ]
        XCTAssertEqual(hostVerifyBinding(binding, probe: changedStart)?.code, .processReplaced)
    }

    func testWindowStrictnessRefusesOnAChangeElsewhereInTheWindowAndElementStrictnessDoesNot() throws {
        // Vector 7. The probe answers for the target element unchanged, but the
        // window digest is recomputed over the whole recorded element set, so a
        // different window title moves it.
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow(title: "Untitled — edited")]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(registry: harness.server.currentRegistry(), session: "s1")
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot, strictness: "window"))
        XCTAssertEqual(try errorCode(harness.awaitResult()), "window_changed")

        // `element` strictness never consults the window digest; it stops at the
        // element, which here is intact, so the refusal comes from the missing
        // Accessibility reference instead.
        harness.send(dispatchElement(snapshot: snapshot, strictness: "element"))
        XCTAssertEqual(try errorCode(harness.awaitResult()), "element_released")
    }

    func testSameAppOcclusionIsWhatTheElementDispatchActuallyApplies() throws {
        // §6.2 — a foreign window stacked above a semantic target has no bearing
        // on whether `AXPress` reaches it, and treating it as occlusion is what
        // made every click on an `apps.launch`ed app refuse.
        var environment = FakeEnvironment()
        environment.windows = [
            hostTestWindow(),
            hostTestWindow(windowId: 2, pid: 9999, appId: "pid:9999", zIndex: 9),
        ]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            elementFrame: HostRect(x: 10, y: 10, width: 20, height: 20)
        )
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot, occlusionPolicy: "same_app"))
        XCTAssertEqual(try errorCode(harness.awaitResult()), "element_released")

        harness.send(dispatchElement(snapshot: snapshot, occlusionPolicy: "any"))
        XCTAssertEqual(try errorCode(harness.awaitResult()), "window_occluded")
    }

    func testADisabledElementIsRefusedBeforeAnythingIsDispatched() throws {
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            enabled: false
        )
        harness.install(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))
        XCTAssertEqual(try errorCode(harness.awaitResult()), "element_disabled")
    }

    // MARK: - Point dispatch compatibility refusal (§6.3)

    func testPointDispatchIsAStableRefusalAndDoesNotTouchTheTarget() throws {
        var environment = FakeEnvironment()
        environment.windows = []
        environment.pointEvents.failure = HostDomainError(.dispatchRefused)

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            image: hostTestImage()
        )
        harness.install(snapshot)

        harness.send(
            dispatchPoint(
                snapshot: snapshot,
                expectDigest: "sha256:" + String(repeating: "c", count: 64),
                x: 100,
                y: 100,
                observeAfter: #"{"includeImage":false,"settle":"quiesce"}"#
            )
        )
        let result = try harness.awaitResult()

        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["outcome"] as? String, "refused")
        XCTAssertEqual(result["tier"] as? String, "coordinate-background")
        XCTAssertEqual(result["path"] as? String, "none")
        XCTAssertEqual(result["effect"] as? String, "unverifiable")
        let verification = try XCTUnwrap(result["verification"] as? [String: Any])
        XCTAssertEqual(verification["method"] as? String, "none")
        XCTAssertEqual(verification["observedChange"] as? Bool, false)
        XCTAssertEqual(try errorCode(result), "unsupported_action")
        XCTAssertTrue(harness.environment.pointEvents.posted.isEmpty)
        XCTAssertEqual(
            harness.server.currentRegistry().snapshotState(session: "s1", snapshotId: snapshot.id),
            .live,
            "a compatibility refusal must not consume snapshot authority"
        )
    }

    func testElementScrollFallsBackToTheBoundPidWithoutUsingGlobalInput() throws {
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            elementFrame: HostRect(x: 10, y: 20, width: 100, height: 80),
            element: hostTestElement(),
            elementActions: [.scrollDown]
        )
        harness.install(snapshot)

        harness.send(
            dispatchElement(
                snapshot: snapshot,
                action: #"{"kind":"scroll","direction":"down","pages":0.5}"#
            )
        )
        let result = try harness.awaitResult()

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["path"] as? String, "cg_event_pid")
        XCTAssertEqual(result["tier"] as? String, "coordinate-background")
        let posted = try XCTUnwrap(harness.environment.pointEvents.posted.first)
        XCTAssertEqual(posted.pid, hostTestPid)
        XCTAssertEqual(posted.path, .cgEventPid)
        XCTAssertEqual(posted.action, .scroll(direction: .down, pages: 0.5))
    }

    // MARK: - Key dispatch (§6.4)

    func testKeyDispatchVerifiesTheBindingAndTheFocusBeforePostingAnything() throws {
        var changed = FakeBindingProbe(override: HostElementDigestInput(role: "AXTextField", label: "Note"))

        var environment = FakeEnvironment()
        environment.probe = changed
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(registry: harness.server.currentRegistry(), session: "s1")
        harness.install(snapshot)

        harness.send(dispatchKey(snapshot: snapshot))
        let result = try harness.awaitResult()
        XCTAssertEqual(try errorCode(result), "element_changed")
        XCTAssertEqual(result["tier"] as? String, "coordinate-background")
        XCTAssertEqual(result["path"] as? String, "none")

        // With the binding intact, focus is still checked: typing into whatever
        // `focusedElement` has become is the same defect as re-resolving an index.
        changed = FakeBindingProbe()
        var focused = FakeEnvironment()
        focused.probe = changed
        focused.windows = [hostTestWindow()]

        let second = ServerHarness(environment: focused)
        try second.begin()
        let live = hostTestSnapshot(registry: second.server.currentRegistry(), session: "s1")
        second.install(live)

        second.send(dispatchKey(snapshot: live))
        XCTAssertEqual(try errorCode(second.awaitResult()), "focus_changed")
    }

    // MARK: - Snapshot state reaches the wire (§4.1)

    func testASpentFrameIsRefusedWithItsOwnCodeOnTheDispatchArm() throws {
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(registry: harness.server.currentRegistry(), session: "s1")
        harness.install(snapshot)
        harness.server.currentRegistry().spend(snapshot)

        harness.send(dispatchElement(snapshot: snapshot))
        let result = try harness.awaitResult()
        XCTAssertEqual(try errorCode(result), "snapshot_spent")
        XCTAssertEqual(result["outcome"] as? String, "refused")
        XCTAssertEqual(result["toolCallId"] as? String, "call_1")
    }

    // MARK: - Requests

    private var nextId = 100

    private func dispatchElement(
        snapshot: HostSnapshot,
        token: String? = nil,
        digest: String? = nil,
        strictness: String = "element",
        occlusionPolicy: String = "none",
        action: String = #"{"kind":"click","button":"left","count":1}"#
    ) -> String {
        nextId += 1
        let element = snapshot.payload.elements[0]
        return """
        {"jsonrpc":"2.0","id":\(nextId),"method":"dispatch.element","params":{\
        "session":"s1","snapshotId":"\(snapshot.id)","toolCallId":"call_1",\
        "elementToken":"\(token ?? element.token)","expectElementDigest":"\(digest ?? element.digest)",\
        "strictness":"\(strictness)","occlusionPolicy":"\(occlusionPolicy)",\
        "action":\(action)}}
        """
    }

    private func dispatchPoint(
        snapshot: HostSnapshot,
        expectDigest: String,
        x: Double = 20,
        y: Double = 20,
        action: String = #"{"kind":"left_click","count":1}"#,
        observeAfter: String? = nil
    ) -> String {
        nextId += 1
        let observe = observeAfter.map { ",\"observeAfter\":\($0)" } ?? ""
        return """
        {"jsonrpc":"2.0","id":\(nextId),"method":"dispatch.point","params":{\
        "session":"s1","snapshotId":"\(snapshot.id)","toolCallId":"call_2",\
        "expectWindowDigest":"\(expectDigest)","point":{"x":\(x),"y":\(y)},"space":"image_px",\
        "occlusionPolicy":"none","action":\(action)\(observe)}}
        """
    }

    private func dispatchKey(snapshot: HostSnapshot) -> String {
        nextId += 1
        let element = snapshot.payload.elements[0]
        return """
        {"jsonrpc":"2.0","id":\(nextId),"method":"dispatch.key","params":{\
        "session":"s1","snapshotId":"\(snapshot.id)","toolCallId":"call_3",\
        "focusToken":"\(element.token)","expectElementDigest":"\(element.digest)",\
        "action":{"kind":"type","text":"hello"}}}
        """
    }

    private func errorCode(_ result: [String: Any]) throws -> String {
        try XCTUnwrap((result["error"] as? [String: Any])?["code"] as? String)
    }
}
