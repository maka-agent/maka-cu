import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Conformance vectors for `maka.cu/3` (§12). Each test here fails without the
/// rule it names; the rules that need a live desktop (real Accessibility
/// invalidation, real capture) are called out in the commit rather than faked.
final class HostProtocolTests: XCTestCase {
    // MARK: - Frame binding (§4)

    func testDispatchQuotingASpentSnapshotFailsWithSnapshotSpent() {
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)
        let snapshot = hostTestSnapshot(registry: registry, session: "s1")
        registry.register(snapshot)

        registry.spend(snapshot)

        let result = registry.resolve(session: "s1", snapshotId: snapshot.id, now: hostNowMs())
        XCTAssertEqual(failureCode(result), .snapshotSpent)
    }

    func testSupersessionIsScopedToTheWindowItObserved() {
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)

        let windowA = hostTestSnapshot(registry: registry, session: "s1")
        let windowB = hostTestSnapshot(registry: registry, session: "s1", window: hostTestWindow(windowId: 2))
        registry.register(windowA)
        registry.register(windowB)

        let laterA = hostTestSnapshot(registry: registry, session: "s1")
        registry.register(laterA)

        XCTAssertEqual(
            failureCode(registry.resolve(session: "s1", snapshotId: windowA.id, now: hostNowMs())),
            .snapshotSuperseded
        )
        XCTAssertNotNil(try? registry.resolve(session: "s1", snapshotId: windowB.id, now: hostNowMs()).get())
        XCTAssertNotNil(try? registry.resolve(session: "s1", snapshotId: laterA.id, now: hostNowMs()).get())
    }

    func testSnapshotOlderThanItsTimeToLiveFailsWithSnapshotExpired() {
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)
        let snapshot = hostTestSnapshot(registry: registry, session: "s1", capturedAt: 0)
        registry.register(snapshot)

        let result = registry.resolve(session: "s1", snapshotId: snapshot.id, now: Int64(HostLimits().snapshotTtlMs))
        XCTAssertEqual(failureCode(result), .snapshotExpired)
    }

    func testOverBudgetSessionEvictsTheOldestSnapshotRatherThanForgettingIt() {
        let limits = HostLimits()
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)

        var snapshots: [HostSnapshot] = []
        for index in 0...limits.snapshotsPerSession {
            let snapshot = hostTestSnapshot(registry: registry, session: "s1", window: hostTestWindow(windowId: CGWindowID(index + 1)))
            registry.register(snapshot)
            snapshots.append(snapshot)
        }

        // The oldest must be distinguishable from one that never existed: a host
        // holding too many frames and a dead executor need different responses.
        XCTAssertEqual(
            failureCode(registry.resolve(session: "s1", snapshotId: snapshots[0].id, now: hostNowMs())),
            .snapshotEvicted
        )
        XCTAssertEqual(
            failureCode(registry.resolve(session: "s1", snapshotId: "snap_nonexistent", now: hostNowMs())),
            .snapshotUnknown
        )
    }

    func testRefusedDispatchLeavesTheSnapshotLiveAndOutcomeUnknownSpendsIt() {
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)
        let snapshot = hostTestSnapshot(registry: registry, session: "s1")
        registry.register(snapshot)

        // A refusal never reaches `spend`, so the host may fix the argument and
        // retry against the same frame.
        XCTAssertEqual(registry.snapshotState(session: "s1", snapshotId: snapshot.id), .live)

        registry.spend(snapshot)
        XCTAssertEqual(registry.snapshotState(session: "s1", snapshotId: snapshot.id), .spent)
    }

    func testSnapshotIdsFromTwoExecutorGenerationsNeverCollide() {
        let first = makeRegistry()
        let second = makeRegistry()

        XCTAssertNotEqual(first.processNonce, second.processNonce)
        XCTAssertNotEqual(first.nextSnapshotId(), second.nextSnapshotId())
        XCTAssertEqual(first.processNonce.count, 32, "the nonce must carry 128 bits")
    }

    func testEndSessionReleasesEverySnapshotAndImageItOwned() {
        var deleted: [String] = []
        let registry = HostSnapshotRegistry(limits: HostLimits(), processNonce: "nonce-a") { deleted.append($0) }
        try? registry.beginSession("s1", captureScope: .window)

        registry.register(hostTestSnapshot(registry: registry, session: "s1", imagePath: "/tmp/a.png"))
        registry.register(hostTestSnapshot(registry: registry, session: "s1", window: hostTestWindow(windowId: 2), imagePath: "/tmp/b.png"))

        let released = registry.endSession("s1")
        XCTAssertEqual(released.snapshots, 2)
        XCTAssertEqual(released.images, 2)
        XCTAssertEqual(released.streams, 0)
        XCTAssertEqual(deleted.sorted(), ["/tmp/a.png", "/tmp/b.png"])
    }

    func testEndingAnUnknownSessionIsIdempotentRatherThanAnError() {
        let registry = makeRegistry()
        let released = registry.endSession("never-begun")
        XCTAssertEqual(released.snapshots, 0)
        XCTAssertEqual(released.images, 0)
    }

    func testSupersededSnapshotLosesItsImageFile() {
        var deleted: [String] = []
        let registry = HostSnapshotRegistry(limits: HostLimits(), processNonce: "nonce-b") { deleted.append($0) }
        try? registry.beginSession("s1", captureScope: .window)

        registry.register(hostTestSnapshot(registry: registry, session: "s1", window: hostTestWindow(windowId: 7), imagePath: "/tmp/old.png"))
        registry.register(hostTestSnapshot(registry: registry, session: "s1", window: hostTestWindow(windowId: 7), imagePath: "/tmp/new.png"))

        // §8 — the image's lifetime is the snapshot's lifetime, so a stale path
        // fails rather than handing back a previous frame's pixels.
        XCTAssertEqual(deleted, ["/tmp/old.png"])
    }

    func testBeginningALiveSessionIdIsRejectedRatherThanSilentlyReset() {
        let registry = makeRegistry()
        XCTAssertNoThrow(try registry.beginSession("s1", captureScope: .window))
        XCTAssertThrowsError(try registry.beginSession("s1", captureScope: .window)) { error in
            XCTAssertEqual((error as? HostRPCError)?.code, .invalidParams)
        }
    }

    // MARK: - Element identity (§4.3)

    func testTokensAreLookedUpByExactStringWithinTheirOwnSnapshot() {
        let registry = makeRegistry()
        try? registry.beginSession("s1", captureScope: .window)
        let first = hostTestSnapshot(registry: registry, session: "s1")
        let second = hostTestSnapshot(registry: registry, session: "s1", window: hostTestWindow(windowId: 2))

        let tokenFromFirst = first.payload.elements[0].token
        XCTAssertNotNil(first.binding(for: tokenFromFirst))
        // A token minted for snapshot A must not resolve inside snapshot B, which
        // is what stops an index from surviving a tree rebuild.
        XCTAssertNil(second.binding(for: tokenFromFirst))
    }

    func testDigestCoversTheUntruncatedValueSoLateEditsStillInvalidate() {
        let long = String(repeating: "a", count: 600)
        let recorded = HostElementDigestInput(role: "AXTextField", untruncatedValue: long)
        let edited = HostElementDigestInput(role: "AXTextField", untruncatedValue: long + "b")

        XCTAssertNotEqual(hostElementDigest(recorded), hostElementDigest(edited))
        XCTAssertEqual(hostChangedDigestFields(recorded: recorded, current: edited), [.value])

        // The wire copy is capped, and the cap is reported rather than implied.
        let wire = hostTruncate(long + "b", limit: 500)
        XCTAssertTrue(wire.wasTruncated)
        XCTAssertEqual(wire.text?.count, 500)
    }

    func testChangedFieldsNameEveryDigestInputThatMoved() {
        let recorded = HostElementDigestInput(
            role: "AXButton",
            label: "Send",
            frameInWindow: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let current = HostElementDigestInput(
            role: "AXButton",
            label: "Sending",
            frameInWindow: CGRect(x: 4, y: 0, width: 10, height: 10)
        )

        XCTAssertEqual(hostChangedDigestFields(recorded: recorded, current: current), [.label, .frame])
    }

    func testBindingVerificationDistinguishesReleasedReplacedAndChanged() {
        let binding = hostTestBinding(token: "el_x", digestInput: HostElementDigestInput(role: "AXButton", label: "Send"))

        var probe = FakeBindingProbe()
        probe.alive = false
        XCTAssertEqual(hostVerifyBinding(binding, probe: probe)?.code, .elementReleased)

        probe = FakeBindingProbe()
        probe.startTime = binding.processStartTime + 1
        XCTAssertEqual(hostVerifyBinding(binding, probe: probe)?.code, .processReplaced)

        probe = FakeBindingProbe(override: HostElementDigestInput(role: "AXButton", label: "Sent"))
        let failure = hostVerifyBinding(binding, probe: probe)
        XCTAssertEqual(failure?.code, .elementChanged)
        XCTAssertEqual(failure?.detail, .changed([.label]))

        probe = FakeBindingProbe()
        XCTAssertNil(hostVerifyBinding(binding, probe: probe))
    }

    func testWindowDigestChangesWhenAnUnrelatedElementChanges() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let before = hostWindowDigest(elementDigests: ["a", "b"], bounds: bounds, title: "Untitled")
        let after = hostWindowDigest(elementDigests: ["a", "c"], bounds: bounds, title: "Untitled")
        let reordered = hostWindowDigest(elementDigests: ["b", "a"], bounds: bounds, title: "Untitled")

        // `strictness: "window"` refuses on this difference; `strictness: "element"`
        // never consults it.
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before, reordered, "the digest is over a sorted set, not an order")
    }

    // MARK: - The two ends of the binding check (§4.3)

    func testTheSnapshotRootTakesNoIdentityFromTheApplicationAboveIt() {
        // §4.3 — the walk is rooted at the window and never sees the application
        // element above it, so inside the frame the root has no ancestors and no
        // siblings. The rule is not decoration: reading the live chain for the
        // root recorded `["AXApplication"]`, the probe answered `[]`, and the
        // window digest differed on a window nothing had touched.
        let button = FakeNode(role: "AXButton", label: "Send", liveAncestorRoles: ["AXGroup", "AXWindow"])
        let group = FakeNode(role: "AXGroup", liveAncestorRoles: ["AXWindow"], children: [button])
        let root = FakeNode(role: "AXWindow", liveAncestorRoles: ["AXApplication"], children: [group])

        let walk = hostWalkTree(
            root: root,
            pid: hostTestPid,
            processStartTime: hostTestProcessStartTime,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 100, maxDepth: 64, maxTextChars: 500)
        )

        XCTAssertEqual(walk.bindings[0].digestInput.ancestorRoles, [])
        XCTAssertEqual(walk.bindings[0].digestInput.siblingIndex, 0)

        // Below the root the chain is the live one, not the walk's own traversal:
        // the walker elides wrapper nodes and `AXParent` does not, and taking the
        // traversal chain here made every Electron target unreachable.
        XCTAssertEqual(walk.bindings[1].digestInput.ancestorRoles, ["AXWindow"])
        XCTAssertEqual(walk.bindings[2].digestInput.ancestorRoles, ["AXGroup", "AXWindow"])
    }

    func testTheTwoEndsOfTheBindingCheckAgreeOnAnElementThatDidNotMove() throws {
        // The walk records the inputs and the probe recomputes them, and §4.3
        // holds only if the two produce the same bytes from the same unchanged
        // element. Asserted at the root, where they once disagreed despite the
        // element itself remaining unchanged.
        let root = FakeNode(role: "AXWindow", title: "Untitled", liveAncestorRoles: ["AXApplication"])

        let walk = hostWalkTree(
            root: root,
            pid: hostTestPid,
            processStartTime: hostTestProcessStartTime,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 100, maxDepth: 64, maxTextChars: 500)
        )

        let binding = walk.bindings[0]
        let probe = FakeRecomputingProbe()
        probe.nodes = [binding.token: root]
        // What a live read answers for a window that is third in `AXWindows`.
        probe.siblingIndexes = [binding.token: 3]

        let recomputed = try XCTUnwrap(probe.currentDigestInput(binding))
        XCTAssertEqual(
            hostChangedDigestFields(recorded: binding.digestInput, current: recomputed),
            [],
            "nothing moved, so no field may differ"
        )
        XCTAssertNil(hostVerifyBinding(binding, probe: probe))
    }

    // MARK: - Bounded observation (§5, §7.4)

    func testTreeOverTheElementBudgetDeclaresTruncationAndStillReturnsUsableTokens() {
        let root = FakeNode(role: "AXWindow", children: (0..<10).map { FakeNode(role: "AXButton\($0)") })

        let walk = hostWalkTree(
            root: root,
            pid: 42,
            processStartTime: 7,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 4, maxDepth: 64, maxTextChars: 500)
        )

        XCTAssertEqual(walk.elements.count, 4)
        XCTAssertTrue(walk.truncated.elements)
        XCTAssertFalse(walk.truncated.depth)
        XCTAssertEqual(Set(walk.elements.map(\.token)).count, 4)
        XCTAssertEqual(walk.bindings.count, 4)
    }

    func testTreeWalkEmitsExactlyTheNumberOfLevelsTheDepthBoundNames() {
        let leaf = FakeNode(role: "AXStaticText")
        let middle = FakeNode(role: "AXGroup", children: [leaf])
        let root = FakeNode(role: "AXWindow", children: [middle])

        let oneLevel = hostWalkTree(
            root: root,
            pid: 42,
            processStartTime: 7,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 100, maxDepth: 1, maxTextChars: 500)
        )

        // A budget of 1 admits the root and nothing under it. Returning at
        // `depth == maxDepth` admitted one level more than the bound named, and
        // the host had no way to see that from the wire.
        XCTAssertEqual(oneLevel.elements.count, 1)
        XCTAssertEqual(oneLevel.elements.map(\.depth), [0])
        XCTAssertTrue(oneLevel.truncated.depth)

        let twoLevels = hostWalkTree(
            root: root,
            pid: 42,
            processStartTime: 7,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 100, maxDepth: 2, maxTextChars: 500)
        )
        XCTAssertEqual(twoLevels.elements.map(\.depth), [0, 1])
        XCTAssertTrue(twoLevels.truncated.depth)

        let whole = hostWalkTree(
            root: root,
            pid: 42,
            processStartTime: 7,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 100, maxDepth: 3, maxTextChars: 500)
        )
        XCTAssertEqual(whole.elements.map(\.depth), [0, 1, 2])
        XCTAssertFalse(whole.truncated.depth)
    }

    func testElementTextTruncationIsReportedPerFieldAndNeverOmitted() {
        let root = FakeNode(role: "AXTextField", value: String(repeating: "x", count: 20))

        let walk = hostWalkTree(
            root: root,
            pid: 1,
            processStartTime: 1,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 10, maxDepth: 10, maxTextChars: 5)
        )

        XCTAssertEqual(walk.elements[0].truncated, [.value])
        XCTAssertEqual(walk.elements[0].value?.count, 5)

        let untouched = hostWalkTree(
            root: FakeNode(role: "AXButton"),
            pid: 1,
            processStartTime: 1,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 10, maxDepth: 10, maxTextChars: 5)
        )
        XCTAssertEqual(untouched.elements[0].truncated, [])
    }

    func testRawAXActionsAreNormalisedOntoTheClosedSet() {
        let root = FakeNode(role: "AXButton", rawActionNames: ["AXPress", "AXShowMenu", "AXSomethingPrivate"])

        let walk = hostWalkTree(
            root: root,
            pid: 1,
            processStartTime: 1,
            tokenPrefix: "snap_test",
            bounds: HostTreeWalkBounds(maxElements: 10, maxDepth: 10, maxTextChars: 500)
        )

        // The host never sees `AXPress`, and an action it could not name in the
        // closed set is an action it could never request.
        XCTAssertEqual(walk.elements[0].actions, [.press, .showMenu])
    }

    func testResponseBudgetHalvesTheElementBoundBeforeGivingUp() {
        var attempts: [Int] = []
        let result = hostFitResponse(maxElements: 1000, limitBytes: 10) { budget in
            attempts.append(budget)
            return (payload: budget, encoded: Data(repeating: 0, count: budget))
        }

        XCTAssertEqual(attempts, [1000, 500, 250, 125])
        XCTAssertEqual(failureCode(result), .responseTooLarge)

        let fits = hostFitResponse(maxElements: 8, limitBytes: 10) { budget in
            (payload: budget, encoded: Data(repeating: 0, count: budget))
        }
        XCTAssertEqual(try? fits.get().payload, 8)
    }

    func testAWalkThatRunsOutOfTimeStopsAndSaysTheTreeIsShort() {
        // §5.2 vector 51 — element count is not a proxy for time. A window hosted
        // in another process costs a round trip per node: an open panel read at
        // 23.6 ms per element, 1500 of them in 35 s, against a host that gives
        // the whole request 20 s and answers an overrun by killing the executor.
        //
        // The clock is injected because the windows that are slow are open and
        // save panels, and no test can put one on the screen. Each read advances
        // it by a second, so the deadline lands after a known number of nodes
        // rather than after a real wait.
        let clock = SteppingClock(step: 1)
        let root = FakeNode(
            role: "AXWindow",
            children: (0..<200).map { FakeNode(role: "AXButton\($0)") }
        )

        let walk = hostWalkTree(
            root: root,
            pid: 42,
            processStartTime: 7,
            tokenPrefix: "snap_slow",
            bounds: HostTreeWalkBounds(
                maxElements: 1500,
                maxDepth: 64,
                maxTextChars: 500,
                deadline: clock.start.addingTimeInterval(4)
            ),
            now: clock.read
        )

        // Stopped where the clock said to, not where the tree ran out: the root
        // is free, the next four reads are inside the deadline, and the fifth is
        // not. 195 children were still there for the taking.
        XCTAssertEqual(walk.elements.count, 5, "the walk ignored its deadline")

        // And what came back is usable: real tokens, real bindings, one per
        // element. A truncated snapshot is still a snapshot.
        XCTAssertEqual(walk.bindings.count, walk.elements.count)
        XCTAssertEqual(Set(walk.elements.map(\.token)).count, walk.elements.count)
        XCTAssertEqual(walk.elements.first?.depth, 0, "the root is always emitted")

        // The part that cannot be silent. `elements` says what came back is
        // short of what the window holds; `depth` is not raised, because no
        // level was the reason.
        XCTAssertTrue(walk.truncated.elements, "a short tree reported as complete is a lie the host acts on")
        XCTAssertFalse(walk.truncated.depth)

        // A walk with time to spare declares nothing, so the flag still means
        // something when it is set.
        let stopped = SteppingClock(step: 0)
        let unhurried = hostWalkTree(
            root: root,
            pid: 42,
            processStartTime: 7,
            tokenPrefix: "snap_fast",
            bounds: HostTreeWalkBounds(
                maxElements: 1500,
                maxDepth: 64,
                maxTextChars: 500,
                deadline: stopped.start.addingTimeInterval(4)
            ),
            now: stopped.read
        )
        XCTAssertEqual(unhurried.elements.count, 201)
        XCTAssertFalse(unhurried.truncated.elements)
        XCTAssertFalse(unhurried.truncated.depth)
    }

    func testTheObservationDeadlineIsSpentOnceAcrossEveryResponseSizeRetry() {
        // §7.5 halves `maxElements` and walks again, up to four times. A budget
        // handed afresh to each attempt is four times the budget — 24 s of a
        // 20 s request deadline — so the deadline is absolute and computed
        // before the first attempt, which is what this asserts: the later
        // attempts start with the clock already past it and stop at the root.
        let clock = SteppingClock(step: 1)
        let deadline = clock.start.addingTimeInterval(3)
        let root = FakeNode(role: "AXWindow", children: (0..<50).map { FakeNode(role: "AXCell\($0)") })

        var counts: [Int] = []
        for budget in [1500, 750, 375, 187] {
            let walk = hostWalkTree(
                root: root,
                pid: 42,
                processStartTime: 7,
                tokenPrefix: "snap_refit",
                bounds: HostTreeWalkBounds(
                    maxElements: budget,
                    maxDepth: 64,
                    maxTextChars: 500,
                    deadline: deadline
                ),
                now: clock.read
            )
            counts.append(walk.elements.count)
            XCTAssertTrue(walk.truncated.elements, "every attempt after the first is out of time and says so")
        }

        XCTAssertEqual(
            Array(counts.dropFirst()),
            [1, 1, 1],
            "a re-walk after the deadline emits the root and stops; it does not get a fresh budget"
        )
    }

    // MARK: - Declared schema (§6.3, §6.5)

    func testTierAndPathPairingsOutsideTheTableAreInconsistent() {
        XCTAssertTrue(hostTierIsConsistent(tier: .ax, path: .axAction))
        XCTAssertTrue(hostTierIsConsistent(tier: .coordinateBackground, path: .cgEventPid))
        XCTAssertTrue(hostTierIsConsistent(tier: .coordinateBackground, path: .skylightPid))
        XCTAssertFalse(hostTierIsConsistent(tier: .ax, path: .cgEventPid))
        XCTAssertFalse(hostTierIsConsistent(tier: .coordinateBackground, path: .axAttribute))
        XCTAssertFalse(hostTierIsConsistent(tier: .semanticBackground, path: .axAction))
    }

    func testSetValueReadbackEqualToThePreviousValueReportsSuspectedNoop() {
        let noop = hostEffectFromValueReadback(requested: "hello", previous: "old", readback: "old")
        XCTAssertEqual(noop.effect, .suspectedNoop)
        XCTAssertEqual(noop.verification.method, .valueReadback)
        XCTAssertFalse(noop.verification.observedChange)

        let confirmed = hostEffectFromValueReadback(requested: "hello", previous: "old", readback: "hello")
        XCTAssertEqual(confirmed.effect, .confirmed)
        XCTAssertTrue(confirmed.verification.observedChange)

        let surprising = hostEffectFromValueReadback(requested: "hello", previous: "old", readback: "something else")
        XCTAssertEqual(surprising.effect, .unverifiable)
        XCTAssertEqual(surprising.verification.method, .valueReadback)
    }

    func testNumericValueReadbackTreatsEquivalentNumberSpellingsAsEqual() {
        let confirmed = hostEffectFromValueReadback(
            requested: "42",
            previous: "25",
            readback: "42.0",
            comparesNumerically: true
        )
        XCTAssertEqual(confirmed.effect, .confirmed)
        XCTAssertTrue(confirmed.verification.observedChange)

        let noop = hostEffectFromValueReadback(
            requested: "42",
            previous: "25.0",
            readback: "25",
            comparesNumerically: true
        )
        XCTAssertEqual(noop.effect, .suspectedNoop)
    }

    func testClickWithoutSettlingNeverClaimsConfirmationFromATreeDelta() {
        let unsettled = hostEffectFromTreeDelta(
            settle: .none,
            digestBefore: "a",
            digestAfter: "b",
            withoutDelta: hostEffectFromActionResult()
        )
        XCTAssertEqual(unsettled.effect, .unverifiable)
        XCTAssertNotEqual(unsettled.verification.method, .treeDelta)

        let settled = hostEffectFromTreeDelta(
            settle: .quiesce,
            digestBefore: "a",
            digestAfter: "b",
            withoutDelta: hostEffectFromActionResult()
        )
        XCTAssertEqual(settled.effect, .confirmed)
        XCTAssertEqual(settled.verification.method, .treeDelta)

        let quiet = hostEffectFromTreeDelta(
            settle: .quiesce,
            digestBefore: "a",
            digestAfter: "a",
            withoutDelta: hostEffectFromActionResult()
        )
        XCTAssertEqual(quiet.effect, .unverifiable)
        XCTAssertEqual(quiet.verification.method, .treeDelta)
        XCTAssertNotEqual(
            quiet.effect,
            .suspectedNoop,
            "the digest covers the elements this snapshot recorded, so a window that did not change is not a window where nothing happened"
        )

        // §6.5 — what "no delta was taken" means is the caller's sentence, not
        // this function's. An `AXPress` has an `action_result` to name; a key
        // posted to a pid has nothing.
        XCTAssertEqual(
            hostEffectFromTreeDelta(
                settle: .none,
                digestBefore: "a",
                digestAfter: nil,
                withoutDelta: hostEffectNotChecked()
            ).verification.method,
            HostVerificationMethod.none
        )
    }

    func testABareActionResultIsNeverConfirmation() {
        let verdict = hostEffectFromActionResult()
        XCTAssertEqual(verdict.effect, .unverifiable)
        XCTAssertEqual(verdict.verification.method, .actionResult)
    }

    func testUnverifiableIsDistinguishableFromNeverChecked() {
        // §6.5 — `effect: unverifiable` with `method: "none"` means never checked;
        // with `method: "value_readback"` it means checked and inconclusive.
        let neverChecked = HostVerification(method: .none, observedChange: false)
        let inconclusive = hostEffectFromValueReadback(requested: "a", previous: "b", readback: nil).verification

        XCTAssertNotEqual(neverChecked.method, inconclusive.method)
    }

    // MARK: - Occlusion (§6.2)

    func testSameAppOcclusionIgnoresForeignWindowsStackedAbove() {
        let point = CGPoint(x: 50, y: 50)
        let covering = CGRect(x: 0, y: 0, width: 100, height: 100)

        // A background app launched by `apps.launch` starts at the bottom of the
        // z-order; treating foreign windows as occlusion refused every semantic
        // click it would ever receive.
        XCTAssertFalse(
            hostIsOccluded(
                policy: .sameApp,
                targetPid: 10,
                targetPoint: point,
                obscuringWindows: [(pid: 99, rect: covering)]
            )
        )

        // A same-app sheet is different: the element underneath is not the thing
        // to act on, whatever the AX tree says.
        XCTAssertTrue(
            hostIsOccluded(
                policy: .sameApp,
                targetPid: 10,
                targetPoint: point,
                obscuringWindows: [(pid: 10, rect: covering)]
            )
        )

        XCTAssertTrue(
            hostIsOccluded(
                policy: .any,
                targetPid: 10,
                targetPoint: point,
                obscuringWindows: [(pid: 99, rect: covering)]
            )
        )

        XCTAssertFalse(
            hostIsOccluded(
                policy: .none,
                targetPid: 10,
                targetPoint: point,
                obscuringWindows: [(pid: 10, rect: covering)]
            )
        )
    }

    // MARK: - Cancellation (§7.2)

    func testCancelBeforeDispatchAppliesAndAfterDispatchIsIgnored() {
        let registry = HostCancellationRegistry()

        registry.cancel(id: 42)
        XCTAssertTrue(registry.isCancelledBeforeDispatch(id: 42))

        registry.markDispatched(id: 42)
        // An action already in flight cannot be un-fired, and reporting `aborted`
        // for one that landed is a lie the host would act on.
        XCTAssertFalse(registry.isCancelledBeforeDispatch(id: 42))

        registry.markDispatched(id: 7)
        registry.cancel(id: 7)
        XCTAssertFalse(registry.isCancelledBeforeDispatch(id: 7))
    }

    // MARK: - Wire shape

    func testDomainFailuresTravelAsResultsNotJSONRPCErrors() throws {
        let line = try HostProtocolCodec.failureResponse(
            id: 3,
            error: HostDomainError(.elementChanged, detail: .changed([.value, .frame])),
            toolCallId: "call_1"
        )
        let json = try jsonObject(line)

        XCTAssertNil(json["error"], "a domain failure is never a JSON-RPC error")
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["toolCallId"] as? String, "call_1")

        let error = try XCTUnwrap(result["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "element_changed")
        XCTAssertEqual(error["message"] as? String, HostDomainErrorCode.elementChanged.message)
        let detail = try XCTUnwrap(error["detail"] as? [String: Any])
        XCTAssertEqual(detail["changed"] as? [String], ["value", "frame"])
    }

    func testEveryDomainCodeCarriesAFixedSentenceWithNoApplicationContent() {
        for code in HostDomainErrorCode.allCases {
            XCTAssertFalse(code.message.isEmpty, "\(code.rawValue) has no fixed sentence")
            XCTAssertFalse(
                code.message.contains(code.rawValue),
                "\(code.rawValue) restates its own code instead of explaining it"
            )
        }
    }

    func testOkResultsCarryTheirFieldsBesideTheTag() throws {
        let line = try HostProtocolCodec.okResponse(
            id: 1,
            payload: HostSessionEndResult(
                released: HostSessionReleaseCounts(snapshots: 3, images: 3, streams: 0)
            )
        )
        let result = try XCTUnwrap(try jsonObject(line)["result"] as? [String: Any])

        XCTAssertEqual(result["ok"] as? Bool, true)
        let released = try XCTUnwrap(result["released"] as? [String: Any])
        XCTAssertEqual(released["snapshots"] as? Int, 3)
    }

    func testNoResponseEverCarriesABase64Image() throws {
        let reference = HostImageReference(
            path: "/tmp/images/snap_1.png",
            format: .png,
            widthPx: 2400,
            heightPx: 1600,
            byteLength: 743_210,
            sha256: "sha256:9d81",
            scale: 2.0
        )
        let line = try HostProtocolCodec.okResponse(
            id: 1,
            payload: HostScreenCaptureResult(image: reference, displayId: "69732928", capturedAt: 1)
        )
        let text = try XCTUnwrap(String(data: line, encoding: .utf8))

        XCTAssertTrue(text.contains("/tmp/images/snap_1.png"))
        XCTAssertFalse(text.contains("\"data\""))
        XCTAssertFalse(text.contains("base64"))
    }

    func testEachEncodedResponseIsExactlyOneLine() throws {
        let line = try HostProtocolCodec.okResponse(id: 1, payload: HostEmptyPayload())
        let text = try XCTUnwrap(String(data: line, encoding: .utf8))

        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
    }

    // MARK: - Handshake and routing (§2, §10)

    func testAnyMethodBeforeHostHelloIsHandshakeRequired() throws {
        let harness = ServerHarness()
        harness.send(#"{"jsonrpc":"2.0","id":1,"method":"observe","params":{"session":"s","target":{"kind":"window","appId":"com.apple.Notes","pid":42,"processGeneration":"pst:1","windowId":7}}}"#)

        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32001)
        XCTAssertEqual(error["message"] as? String, "handshake_required")
    }

    func testUnknownProtocolVersionIsFatalAndNamesWhatIsSupported() throws {
        let harness = ServerHarness()
        // §2 — `maka.cu/1` is withdrawn, not deprecated: the parts of it that
        // moved are exactly the parts its two implementations disagreed about.
        harness.sendHello(protocolVersion: "maka.cu/1")

        let response = try harness.awaitResponse()
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32000)
        XCTAssertEqual(error["message"] as? String, "protocol_version_mismatch")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["supported"] as? [String], ["maka.cu/3"])

        // §2 — `EX_CONFIG`, so the host classifies the start as `service_mismatch`
        // and does not retry.
        XCTAssertEqual(harness.server.exitStatus, 78)
    }

    func testHandshakeAnswersWithEveryLimitTheHostWouldOtherwiseHardcode() throws {
        let harness = ServerHarness()
        harness.sendHello()

        let result = try XCTUnwrap(try harness.awaitResponse()["result"] as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["protocol"] as? String, "maka.cu/3")

        let limits = try XCTUnwrap(result["limits"] as? [String: Any])
        for key in [
            "snapshotsPerSession", "snapshotTtlMs", "maxElements", "maxDepth", "maxTextChars",
            "maxResponseBytes", "settleCeilingMs", "treeWalkCeilingMs", "shutdownGraceMs",
            "imageDirBudgetBytes",
        ] {
            XCTAssertNotNil(limits[key], "\(key) must travel in the handshake")
        }

        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["captureStream"] as? Bool, false)
    }

    func testHandshakeFailsWhenTheImageDirectoryIsNotWritable() throws {
        let harness = ServerHarness()
        harness.sendHello(imageDir: "/var/db/maka-cu-does-not-exist")

        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual((error["data"] as? [String: Any])?["field"] as? String, "imageDir")
    }

    func testCaptureStreamMethodsAnswerNotImplementedAsADomainResult() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        for method in ["capture.start", "capture.next", "capture.stop"] {
            harness.send(#"{"jsonrpc":"2.0","id":9,"method":"\#(method)","params":{}}"#)
            let response = try harness.awaitResponse()

            XCTAssertNil(response["error"], "\(method) must not be -32601")
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "not_implemented")
        }
    }

    func testSessionEndAnswersWithItsReleaseCountsRatherThanHanging() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        XCTAssertEqual((try harness.awaitResponse()["result"] as? [String: Any])?["ok"] as? Bool, true)

        // Teardown must answer. An earlier revision reached into the AppKit cursor
        // overlay from the session lane, which blocked on `DispatchQueue.main.sync`
        // against a main thread parked in `readLine` and never replied at all.
        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"session.end","params":{"session":"s1"}}"#)
        let result = try XCTUnwrap(try harness.awaitResponse()["result"] as? [String: Any])
        let released = try XCTUnwrap(result["released"] as? [String: Any])
        XCTAssertEqual(released["snapshots"] as? Int, 0)
        XCTAssertEqual(released["images"] as? Int, 0)
        XCTAssertEqual(released["streams"] as? Int, 0)
    }

    func testBeginningTheSameSessionTwiceIsRejectedOverTheWire() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testAnUnknownMethodIsAJSONRPCErrorRatherThanADomainResult() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":5,"method":"observe.everything","params":{}}"#)
        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testAMethodNamingAnUnknownSessionIsSessionUnknown() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":6,"method":"observe","params":{"session":"never-begun","target":{"kind":"window","appId":"com.apple.Notes","pid":42,"processGeneration":"pst:1","windowId":7}}}"#)
        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32002)
    }

    func testNonJSONInputIsAParseErrorRatherThanASilentDrop() throws {
        let harness = ServerHarness()
        harness.send("this is not json")

        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
    }

    func testObserveBoundsAboveTheLimitAreRejectedRatherThanClamped() throws {
        let harness = ServerHarness()
        harness.sendHello()
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"s1","captureScope":"window"}}"#)
        _ = try harness.awaitResponse()

        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"observe","params":{"session":"s1","target":{"kind":"window","appId":"pid:1","pid":1,"processGeneration":"pst:1","windowId":1},"maxElements":999999}}"#)
        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual((error["data"] as? [String: Any])?["field"] as? String, "maxElements")
    }

    func testCancelNotificationProducesNoResponse() throws {
        let harness = ServerHarness()
        harness.send(#"{"jsonrpc":"2.0","method":"$/cancel","params":{"id":42}}"#)

        XCTAssertThrowsError(try harness.awaitResponse(timeout: 0.2))
    }

    // MARK: - Capture geometry (§6.6, §12 vectors 48–49)

    /// §12.48 — `CuAction.screenshot` is defined to arrive with no target, so a
    /// required `displayId` makes `-32602` the answer to the only request this
    /// method exists to serve. Asserted on the decoder rather than through a
    /// capture because the capture itself needs a compositor; the live half of
    /// this vector is in `HostCaptureLiveTests`.
    func testScreenCaptureAcceptsARequestThatNamesNoDisplay() throws {
        let omitted = try JSONDecoder().decode(
            HostScreenCaptureParams.self,
            from: Data(#"{"session":"s1"}"#.utf8)
        )
        XCTAssertNil(omitted.displayId)

        let named = try JSONDecoder().decode(
            HostScreenCaptureParams.self,
            from: Data(#"{"session":"s1","displayId":"69732928"}"#.utf8)
        )
        XCTAssertEqual(named.displayId, "69732928")
    }

    /// §12.49 — the pair to the vector above. An executor that made `displayId`
    /// optional by falling back to the main display whenever the lookup fails
    /// passes 48 and fails here, and it fails by returning a picture of the main
    /// display under the display id the caller asked for.
    ///
    /// `0` is `kCGNullDirectDisplay` and `4294967295` is the top of the id
    /// space; neither is ever an attached display, on any machine, so this runs
    /// without a desktop.
    func testScreenCaptureRejectsADisplayIdThatNamesNoAttachedDisplay() throws {
        for (index, displayId) in ["0", "4294967295", "not-a-number"].enumerated() {
            let harness = ServerHarness()
            _ = try harness.begin()

            harness.send(
                #"{"jsonrpc":"2.0","id":\#(30 + index),"method":"screen.capture","#
                    + #""params":{"session":"s1","displayId":"\#(displayId)"}}"#
            )
            let response = try harness.awaitResponse()

            XCTAssertNil(
                response["result"],
                "screen.capture must not answer \(displayId) with a picture of some other display"
            )
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32602, "displayId \(displayId)")
            XCTAssertEqual((error["data"] as? [String: Any])?["field"] as? String, "displayId")
        }
    }

    /// The list `screen.capture` validates against has to be the machine's, and
    /// it has to contain the display the default resolves to — otherwise the
    /// validation above would reject the executor's own fallback.
    func testTheActiveDisplayListComesFromTheWindowServerAndContainsTheMainDisplay() {
        let ids = hostActiveDisplayIds()

        XCTAssertFalse(ids.isEmpty, "a machine running this test has at least one display")
        XCTAssertTrue(ids.contains(CGMainDisplayID()))
        XCTAssertFalse(ids.contains(0), "0 is kCGNullDirectDisplay, not a display")
    }

    // MARK: - Key vocabulary (§6.4)

    func testKeyNamesOutsideTheClosedSetAreRejected() {
        XCTAssertTrue(hostKeyNameIsSupported("Return"))
        XCTAssertTrue(hostKeyNameIsSupported("F12"))
        XCTAssertTrue(hostKeyNameIsSupported("a"))
        XCTAssertTrue(hostKeyNameIsSupported("~"))
        XCTAssertFalse(hostKeyNameIsSupported("super+shift+q"))
        XCTAssertFalse(hostKeyNameIsSupported("Eject"))
        XCTAssertFalse(hostKeyNameIsSupported(""))
    }

    func testTheTwoAmbiguousKeyNamesAreNotInTheSet() {
        // §6.4 — `Enter` was a second name for `Return`, and `Delete` is the
        // backspace legend on a Mac and the forward delete in xdotool: one
        // string, two destructive meanings, no way to tell which was meant.
        XCTAssertFalse(hostKeyNameIsSupported("Enter"))
        XCTAssertFalse(hostKeyNameIsSupported("Delete"))
        XCTAssertTrue(hostKeyNameIsSupported("Backspace"))
        XCTAssertTrue(hostKeyNameIsSupported("ForwardDelete"))

        // The printable range starts at U+0021: `Space` is the only spelling of
        // the space bar.
        XCTAssertFalse(hostKeyNameIsSupported(" "))
        XCTAssertTrue(hostKeyNameIsSupported("Space"))
    }

    func testACombinationReachingTheExecutorIsInvalidParamsNotAGuess() throws {
        // §6.4 vector 36 — the host parses; the closed set stays closed, and a
        // host that sent a combination has a bug worth seeing.
        let harness = ServerHarness()
        try harness.begin()

        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"dispatch.key","params":{"session":"s1","snapshotId":"snap_x","toolCallId":"call_1","focusToken":"el_1","expectElementDigest":"sha256:aa","action":{"kind":"key","key":"cmd+a"}}}"#)

        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual((error["data"] as? [String: Any])?["field"] as? String, "key")
    }

    func testEveryKeyTheWireAdvertisesResolvesToAStrokeCarryingACharacter() {
        // §12 vector 54 — the set the decoder accepts and the set the dispatcher
        // can post are one set, and every member of it carries characters.
        //
        // `hostNamedKeys` is 26 names and the printable range is U+0021–U+007E,
        // which is 94 characters: 120 members, all of them enumerated here rather
        // than sampled, because a member the wire advertises and the executor
        // cannot build is exactly the defect a sample misses.
        XCTAssertEqual(hostNamedKeys.count, 26)

        var members: [String] = hostNamedKeys.sorted()
        members.append(contentsOf: (0x21...0x7E).map { String(UnicodeScalar($0)!) })
        XCTAssertEqual(members.count, 120)

        for member in members {
            guard let stroke = hostKeyStroke(name: member, modifiers: []) else {
                XCTFail("\(member) is in the closed set and has no stroke to post")
                continue
            }

            XCTAssertFalse(
                stroke.characters.isEmpty,
                "\(member) posts an event with no characters, which is an event the application does nothing with"
            )
            XCTAssertTrue(hostKeyNameIsSupported(member))
        }

        // And nothing outside it resolves, so the guard in `postKeyEvent` is
        // unreachable rather than load-bearing.
        XCTAssertNil(hostKeyStroke(name: " ", modifiers: []), "Space is the only spelling of the space bar")
        XCTAssertNil(hostKeyStroke(name: "Enter", modifiers: []))
        XCTAssertNil(hostKeyStroke(name: "cmd+a", modifiers: []))
        XCTAssertNil(hostKeyStroke(name: "£", modifiers: []))
    }

    func testAKeyEventCarriesTheCharacterTheApplicationActsOnAndNotTheLayoutsTranslation() throws {
        // §12 vector 54. The event `CGEvent(keyboardEventSource:virtualKey:)`
        // hands back is not characterless — it carries the *keyboard layout's*
        // translation of the key code, and for most of the named set that is not
        // the character the application acts on. Measured: the right arrow
        // translates to U+001D where AppKit binds U+F703, `ForwardDelete`
        // translates to U+007F — which is the *backspace* key's character, so an
        // executor trusting the layout deletes in the wrong direction — and all
        // twelve function keys collapse onto one U+0010.
        //
        // So each row asserts both halves: the character is the one AppKit binds,
        // and it is not the one the layout would have supplied. The second half
        // is what fails against the executor that shipped, which built the event
        // and posted it unmodified.
        let expected: [(name: String, character: String, keyCode: CGKeyCode)] = [
            ("Right", "\u{F703}", CGKeyCode(kVK_RightArrow)),
            ("Left", "\u{F702}", CGKeyCode(kVK_LeftArrow)),
            ("Up", "\u{F700}", CGKeyCode(kVK_UpArrow)),
            ("Down", "\u{F701}", CGKeyCode(kVK_DownArrow)),
            ("Home", "\u{F729}", CGKeyCode(kVK_Home)),
            ("End", "\u{F72B}", CGKeyCode(kVK_End)),
            ("PageUp", "\u{F72C}", CGKeyCode(kVK_PageUp)),
            ("PageDown", "\u{F72D}", CGKeyCode(kVK_PageDown)),
            ("Backspace", "\u{007F}", CGKeyCode(kVK_Delete)),
            ("ForwardDelete", "\u{F728}", CGKeyCode(kVK_ForwardDelete)),
            ("F1", "\u{F704}", CGKeyCode(kVK_F1)),
            ("F5", "\u{F708}", CGKeyCode(kVK_F5)),
            ("F12", "\u{F70F}", CGKeyCode(kVK_F12)),
            // A printable character the layout only produces with shift held, so
            // the key code alone answers with the unshifted one.
            ("A", "A", CGKeyCode(kVK_ANSI_A)),
            ("!", "!", CGKeyCode(kVK_ANSI_1)),
        ]

        for row in expected {
            let stroke = try XCTUnwrap(hostKeyStroke(name: row.name, modifiers: []))
            XCTAssertEqual(stroke.keyCode, row.keyCode, row.name)

            let sequence = try InputSimulation.keyEvents(for: stroke)
            XCTAssertEqual(characters(of: sequence.keyDown), row.character, "key down for \(row.name)")
            XCTAssertEqual(characters(of: sequence.keyUp), row.character, "key up for \(row.name)")
            XCTAssertEqual(sequence.keyDown.getIntegerValueField(.keyboardEventKeycode), Int64(row.keyCode))
            XCTAssertTrue(sequence.modifierDowns.isEmpty, "\(row.name) declared no modifiers to hold")

            let untouched = try XCTUnwrap(
                CGEvent(keyboardEventSource: nil, virtualKey: row.keyCode, keyDown: true)
            )
            XCTAssertNotEqual(
                characters(of: untouched),
                row.character,
                "\(row.name): the layout answers this key code differently, so an executor that posts the event as built posts the wrong character"
            )
        }

        // The four the layout does get right, asserted anyway: they are still
        // dispatched from the table rather than left to whatever input source is
        // selected, and the live half is what shows they now arrive.
        for row in [("Tab", "\u{0009}"), ("Return", "\u{000D}"), ("Escape", "\u{001B}"), ("Space", "\u{0020}")] {
            let stroke = try XCTUnwrap(hostKeyStroke(name: row.0, modifiers: []))
            XCTAssertEqual(characters(of: try InputSimulation.keyEvents(for: stroke).keyDown), row.1, row.0)
        }
    }

    func testShiftIsTheOneModifierThatChangesWhichCharacterIsPosted() throws {
        // A printable key has a second character and `shift` is how the wire asks
        // for it: an event carrying `a` while claiming shift is held is an event
        // that disagrees with itself, and the application acts on the character.
        let shifted = try XCTUnwrap(hostKeyStroke(name: "a", modifiers: [.shift]))
        XCTAssertEqual(characters(of: try InputSimulation.keyEvents(for: shifted).keyDown), "A")
        XCTAssertEqual(shifted.keyCode, CGKeyCode(kVK_ANSI_A), "the same physical key")

        // Idempotent: a character that is already the shifted form stays itself.
        let already = try XCTUnwrap(hostKeyStroke(name: "!", modifiers: [.shift]))
        XCTAssertEqual(characters(of: try InputSimulation.keyEvents(for: already).keyDown), "!")

        // A named key has no second character. `shift+Tab` is U+0009 with a shift
        // flag on it, and what that means is the application's decision.
        let tab = try XCTUnwrap(hostKeyStroke(name: "Tab", modifiers: [.shift]))
        XCTAssertEqual(characters(of: try InputSimulation.keyEvents(for: tab).keyDown), "\u{0009}")

        // And no other modifier touches it: `cmd+a` is the character `a` under a
        // command flag — which is a stroke that does not carry its characters at
        // all, and the next test is why.
        let command = try XCTUnwrap(hostKeyStroke(name: "a", modifiers: [.command]))
        XCTAssertEqual(command.characters, Array("a".utf16))
    }

    func testACommandStrokeDoesNotCarryItsCharactersBecauseAMenuEquivalentCannotSurviveThem() throws {
        // §12 vector 54 — the one exception, and it is a measurement rather than
        // caution. `performKeyEquivalent:` matches a menu command against the
        // application's own translation of the key code; an event that arrives
        // with characters on it is taken as text and never offered to that path.
        // Measured on a real TextEdit document, resetting the selection through
        // Accessibility between rows: frontmost `cmd+a` plain selects the
        // document and frontmost `cmd+a` carrying "a" does nothing at all.
        let command = try XCTUnwrap(hostKeyStroke(name: "a", modifiers: [.command]))
        XCTAssertFalse(command.carriesCharacters)
        XCTAssertEqual(
            command.characters,
            Array("a".utf16),
            "the stroke still knows the character; what it declines to do is put it on the event"
        )

        // Every other modifier keeps them, because every other modifier reaches
        // the application through the responder chain, which is the path that
        // needs characters to work at all in the background: measured,
        // `shift+Right`, `option+Right` and `control+e` all land on a background
        // TextEdit carrying the character the key produces.
        for modifiers in [[HostKeyModifier.shift], [.option], [.control], [.fn], []] {
            let stroke = try XCTUnwrap(hostKeyStroke(name: "Right", modifiers: modifiers))
            XCTAssertTrue(stroke.carriesCharacters, "\(modifiers)")
            XCTAssertEqual(characters(of: try InputSimulation.keyEvents(for: stroke).keyDown), "\u{F703}", "\(modifiers)")
        }

        // The command flag is still on the event, and the modifier is still held
        // around it. Dropping the characters is not dropping the shortcut.
        let sequence = try InputSimulation.keyEvents(for: command)
        XCTAssertTrue(sequence.keyDown.flags.contains(.maskCommand))
        XCTAssertEqual(sequence.modifierDowns.count, 1)
        XCTAssertEqual(sequence.keyDown.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_A))
    }

    func testModifiersAreHeldAroundTheKeyAndFnTravelsAsAFlag() throws {
        let stroke = try XCTUnwrap(hostKeyStroke(name: "Return", modifiers: [.command, .shift]))
        XCTAssertTrue(stroke.flags.contains(.maskCommand))
        XCTAssertTrue(stroke.flags.contains(.maskShift))

        let sequence = try InputSimulation.keyEvents(for: stroke)
        XCTAssertEqual(sequence.modifierDowns.count, 2, "one key-down per modifier that has a key code")
        XCTAssertEqual(sequence.modifierUps.count, 2)
        XCTAssertEqual(
            sequence.modifierDowns.map { $0.getIntegerValueField(.keyboardEventKeycode) },
            [Int64(kVK_Shift), Int64(kVK_Command)]
        )
        XCTAssertEqual(
            sequence.modifierUps.map { $0.getIntegerValueField(.keyboardEventKeycode) },
            [Int64(kVK_Command), Int64(kVK_Shift)],
            "released in the reverse of the order they were held"
        )
        XCTAssertEqual(sequence.keyDown.flags.rawValue & CGEventFlags.maskCommand.rawValue, CGEventFlags.maskCommand.rawValue)

        // `fn` has no key code to hold down, so it is a flag on the events and
        // nothing extra in the sequence.
        let fn = try XCTUnwrap(hostKeyStroke(name: "Left", modifiers: [.fn]))
        XCTAssertTrue(fn.flags.contains(.maskSecondaryFn))
        let fnSequence = try InputSimulation.keyEvents(for: fn)
        XCTAssertTrue(fnSequence.modifierDowns.isEmpty)
        XCTAssertTrue(fnSequence.keyDown.flags.contains(.maskSecondaryFn))
        XCTAssertEqual(characters(of: fnSequence.keyDown), "\u{F702}")
    }

    /// What the application will read off the event, read back the same way.
    private func characters(of event: CGEvent) -> String {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else {
            return ""
        }

        var buffer = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }

    // MARK: - Focus policy (§6.4)

    func testDispatchKeyWithoutAFocusPolicyRequiresFocusAndNeverMovesIt() throws {
        // §6.4 vector 40 — the default is `require`, so a host that says nothing
        // gets exactly the check it always got: focus elsewhere is
        // `focus_changed`, and no `kAXFocused` write is attempted.
        let element = hostTestElement()
        var elsewhere = FakeEnvironment()
        elsewhere.windows = [hostTestWindow()]
        elsewhere.focused = hostTestElement(pid: hostTestPid + 1)

        let refused = ServerHarness(environment: elsewhere)
        try refused.begin()
        let missed = hostTestSnapshot(
            registry: refused.server.currentRegistry(),
            session: "s1",
            element: element
        )
        refused.install(missed)

        refused.send(dispatchKey(snapshot: missed))
        let refusal = try refused.awaitResult()
        XCTAssertEqual(try errorCode(refusal), "focus_changed")
        XCTAssertTrue(refused.environment.focusRequests.requested.isEmpty, "`require` never writes focus")
        XCTAssertTrue(refused.environment.keyEvents.posted.isEmpty)

        // And with focus already on the named element it posts, still without
        // writing focus.
        var onTarget = FakeEnvironment()
        onTarget.windows = [hostTestWindow()]
        onTarget.focused = element

        let harness = ServerHarness(environment: onTarget)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: element
        )
        harness.install(snapshot)

        harness.send(dispatchKey(snapshot: snapshot))
        let result = try harness.awaitResult()
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["outcome"] as? String, "ok")
        XCTAssertEqual(result["path"] as? String, "cg_event_pid")
        XCTAssertTrue(harness.environment.focusRequests.requested.isEmpty)
        XCTAssertEqual(harness.environment.keyEvents.posted, [.type("hello")])
    }

    func testAcquireFocusesTheNamedElementBeforePostingTheKey() throws {
        // §6.4 vector 40 — the whole point of the policy: the host stops having
        // to click a control to focus it, which on a button is a press.
        let element = hostTestElement()
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]
        environment.focused = hostTestElement(pid: hostTestPid + 1)

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: element
        )
        harness.install(snapshot)

        harness.send(dispatchKey(snapshot: snapshot, focusPolicy: "acquire"))
        let result = try harness.awaitResult()

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["outcome"] as? String, "ok")
        XCTAssertEqual(harness.environment.focusRequests.requested.count, 1)
        XCTAssertEqual(harness.environment.keyEvents.posted, [.type("hello")])
    }

    func testAcquireIsRefusedWhenTheElementDoesNotTakeFocus() throws {
        // §6.4 vector 41 — two ways to fail, one answer, and no key either time.
        // A refused write is the obvious one; the write that is accepted while
        // focus stays put is why the executor re-reads instead of trusting it.
        for (label, configure) in [
            ("the write is refused", { (log: FocusRequestLog) in log.writeSucceeds = false }),
            ("focus does not follow", { (log: FocusRequestLog) in log.focusFollows = false }),
        ] {
            let element = hostTestElement()
            var environment = FakeEnvironment()
            environment.windows = [hostTestWindow()]
            environment.focused = hostTestElement(pid: hostTestPid + 1)
            configure(environment.focusRequests)

            let harness = ServerHarness(environment: environment)
            try harness.begin()
            let snapshot = hostTestSnapshot(
                registry: harness.server.currentRegistry(),
                session: "s1",
                element: element
            )
            harness.install(snapshot)

            harness.send(dispatchKey(snapshot: snapshot, focusPolicy: "acquire"))
            let result = try harness.awaitResult()

            XCTAssertEqual(try errorCode(result), "focus_changed", "\(label)")
            XCTAssertEqual(result["outcome"] as? String, "refused", "\(label)")
            XCTAssertEqual(result["path"] as? String, "none", "\(label)")
            XCTAssertEqual(harness.environment.focusRequests.requested.count, 1, "\(label)")
            XCTAssertTrue(harness.environment.keyEvents.posted.isEmpty, "\(label)")
        }
    }

    func testAFocusPolicyOutsideTheClosedSetIsInvalidParams() throws {
        // §6.4 vector 42 — the set is `require` / `acquire`. Nothing here falls
        // back to the strict path: a host asking for a third behaviour has a bug
        // worth seeing, and answering it as `require` hides that.
        let harness = ServerHarness()
        try harness.begin()

        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"dispatch.key","params":{"session":"s1","snapshotId":"snap_x","toolCallId":"call_1","focusToken":"el_1","expectElementDigest":"sha256:aa","focusPolicy":"steal","action":{"kind":"type","text":"hello"}}}"#)

        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual((error["data"] as? [String: Any])?["field"] as? String, "focusPolicy")
    }

    // MARK: - Which evidence judges which action (§6.5)

    func testTypingIsJudgedByTheValueAndAKeyIsNot() {
        // §6.5 vector 53 — the split is on what the action does. `type` writes
        // into the element the request named, so that element's value answers the
        // question; a key is a command the application interprets, and the
        // modifier list is not what makes it one.
        XCTAssertEqual(hostKeyEvidence(for: .type("hello")), .focusedElementValue)
        XCTAssertEqual(hostKeyEvidence(for: .key(name: "p", modifiers: [.command])), .windowDelta)
        XCTAssertEqual(hostKeyEvidence(for: .key(name: "F2", modifiers: [.control])), .windowDelta)
        XCTAssertEqual(hostKeyEvidence(for: .key(name: "Tab", modifiers: [])), .windowDelta)
        XCTAssertEqual(hostKeyEvidence(for: .key(name: "Escape", modifiers: [])), .windowDelta)
    }

    func testACombinationKeyIsNeverSuspectedNoopBecauseTheFocusedValueDidNotMove() throws {
        // §6.5 vector 53 — the reproduction. `cmd+p` opens a print sheet and
        // leaves the focused text element's value exactly where it was, which the
        // executor read back and reported as `suspected_noop`: a claim to have
        // checked, made by a check with no bearing on the question. Measured on a
        // real run, a model sent `cmd+p` seven times against that answer and then
        // apologised for arguments that had been right all along.
        //
        // The window here does not change either, so the honest answer is
        // `unverifiable` with the method that was actually consulted named.
        let element = hostTestElement()
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]
        environment.focused = element
        environment.probe = KeyReactiveProbe(log: environment.keyEvents)

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: element
        )
        harness.install(snapshot)

        harness.send(
            dispatchKey(
                snapshot: snapshot,
                action: #"{"kind":"key","key":"p","modifiers":["command"]}"#,
                settle: "quiesce"
            )
        )
        let result = try harness.awaitResult(timeout: 10)

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["outcome"] as? String, "ok")
        XCTAssertEqual(harness.environment.keyEvents.posted, [.key(name: "p", modifiers: [.command])])
        XCTAssertNotEqual(
            result["effect"] as? String,
            "suspected_noop",
            "a key the focused element's value cannot report on was never checked for a noop"
        )
        XCTAssertEqual(result["effect"] as? String, "unverifiable")
        XCTAssertEqual(
            (result["verification"] as? [String: Any])?["method"] as? String,
            "tree_delta",
            "settling was asked for, so the window is what was consulted"
        )
        XCTAssertEqual((result["verification"] as? [String: Any])?["observedChange"] as? Bool, false)
    }

    func testAKeyThatChangesTheWindowIsConfirmedByTheWindow() throws {
        // §6.5 vector 53 — the other half. The window delta can confirm even
        // though it can never refute, and it is the only evidence a key gets.
        let element = hostTestElement()
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]
        environment.focused = element
        environment.probe = KeyReactiveProbe(
            log: environment.keyEvents,
            after: HostElementDigestInput(role: "AXButton", label: "Print…")
        )

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: element
        )
        harness.install(snapshot)

        harness.send(
            dispatchKey(
                snapshot: snapshot,
                action: #"{"kind":"key","key":"p","modifiers":["command"]}"#,
                settle: "quiesce"
            )
        )
        let result = try harness.awaitResult(timeout: 10)

        XCTAssertEqual(result["effect"] as? String, "confirmed")
        XCTAssertEqual((result["verification"] as? [String: Any])?["method"] as? String, "tree_delta")
        XCTAssertEqual((result["verification"] as? [String: Any])?["observedChange"] as? Bool, true)
    }

    func testAKeyWithNoSettleReportsThatNothingWasChecked() throws {
        // §6.5 vector 53 — with no settle there is no delta, and a key posted to a
        // pid returns nothing to name either. `unverifiable` with `method: "none"`
        // is the whole of what the executor knows, and it is a different sentence
        // from `unverifiable` with a method: that one means it looked.
        let element = hostTestElement()
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]
        environment.focused = element
        environment.probe = KeyReactiveProbe(log: environment.keyEvents)

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: element
        )
        harness.install(snapshot)

        harness.send(
            dispatchKey(snapshot: snapshot, action: #"{"kind":"key","key":"Escape","modifiers":[]}"#)
        )
        let result = try harness.awaitResult()

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertNotEqual(result["effect"] as? String, "suspected_noop")
        XCTAssertEqual(result["effect"] as? String, "unverifiable")
        XCTAssertEqual((result["verification"] as? [String: Any])?["method"] as? String, "none")
    }

    func testTypingIsNotJudgedByTheWindowEvenWhenTheWindowChanged() throws {
        // §6.5 vector 53, the guard on the fix rather than on the defect. Routing
        // every `dispatch.key` through the window delta would trade one misreport
        // for another: typing that left the element's value alone would come back
        // `confirmed` off some unrelated change elsewhere in the window, and the
        // one action whose noop *is* observable would stop being observable.
        let element = hostTestElement()
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]
        environment.focused = element
        environment.probe = KeyReactiveProbe(
            log: environment.keyEvents,
            after: HostElementDigestInput(role: "AXButton", label: "Sent")
        )

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: element
        )
        harness.install(snapshot)

        harness.send(dispatchKey(snapshot: snapshot, settle: "quiesce"))
        let result = try harness.awaitResult(timeout: 10)

        XCTAssertEqual(harness.environment.keyEvents.posted, [.type("hello")])
        XCTAssertNotEqual(
            (result["verification"] as? [String: Any])?["method"] as? String,
            "tree_delta",
            "typing is judged by the value it writes, whatever else the window did"
        )
    }

    // MARK: - Settling a window that is expensive to look at (§6.1, §12 vector 55)

    func testASettleStoppedByTheBudgetReportsTheTimeItReallySpent() {
        // Vector 55 — `waitedMs` is measured on every arm. The loop that shipped
        // answered its timeout arm with `limits.settleCeilingMs`, a constant, so
        // a settle that really took 3.7 s told the host 2500 — and `waitedMs` is
        // the field the host traces to see overruns, so the fabricated value hid
        // the overrun from the only instrument pointed at it.
        //
        // Four looks at 500 ms with a 50 ms wait between them: the fourth ends at
        // 2150 ms and there is not enough budget left for a fifth, so 2150 is the
        // answer. Not 2500, and not 2500 by coincidence either.
        let settled = drivenSettle(costPerLook: 0.5, stable: false)

        XCTAssertEqual(settled.report.reason, .ceiling)
        XCTAssertFalse(settled.report.quiesced)
        XCTAssertEqual(settled.looks, 4)
        XCTAssertEqual(settled.report.waitedMs, 2150)
        XCTAssertNotEqual(
            settled.report.waitedMs,
            HostLimits().settleCeilingMs,
            "a settle that reports the ceiling as its duration is reporting the constant, not the clock"
        )
    }

    func testAWindowTooExpensiveToLookAtTwiceSaysSoRatherThanSpendingTheBudget() {
        // Vector 55 — proving a window quiet takes two looks that agree, so a
        // window whose one look costs more than the budget has left cannot be
        // proven quiet at all. Measured: one look at System Settings' 337
        // elements takes 2.2 s and one at a 1225-element Finder window takes
        // 3.6 s, against a 2.5 s budget.
        //
        // The window here is genuinely still — the digest never changes — which
        // is the case the old loop got least honest about: it began a second look
        // at 1850 ms because it only tested the clock at the top of the round,
        // ran 1100 ms past the budget, and reported `quiesced: true` for a wait it
        // was never entitled to make.
        let settled = drivenSettle(costPerLook: 1.8, stable: true)

        XCTAssertEqual(settled.report.reason, .windowTooSlow)
        XCTAssertFalse(settled.report.quiesced)
        XCTAssertEqual(settled.looks, 1, "the second look was not affordable and was not taken")
        XCTAssertEqual(settled.report.waitedMs, 1800)
        XCTAssertFalse(
            settled.digest.isEmpty,
            "the one look is still evidence: §6.5 judges the dispatch by this digest"
        )
        XCTAssertEqual(HostSettleReason.windowTooSlow.rawValue, "window_too_slow")
    }

    func testAnOrdinaryWindowStillQuiescesOnTheSecondLook() {
        // Vector 55, the guard on the fix rather than on the defect. Refusing to
        // begin a look the budget cannot pay for must not refuse the ordinary
        // one: a 230 ms look — the cost of a few hundred elements in a window
        // that draws its own — lands the second at 510 ms with 2 s to spare, and
        // the answer is `quiesced`.
        let settled = drivenSettle(costPerLook: 0.23, stable: true)

        XCTAssertEqual(settled.report.reason, .quiesced)
        XCTAssertTrue(settled.report.quiesced)
        XCTAssertEqual(settled.looks, 2)
        // Within a millisecond rather than to it: this vector is about the
        // ordinary window still settling, not about how the duration rounds.
        XCTAssertLessThanOrEqual(abs(settled.report.waitedMs - 510), 1)
    }

    func testTheWireCarriesTheTimeTheSettleReallySpentAndNamesWhyItStopped() throws {
        // Vector 55 on the wire, driven by a probe that costs real time, because
        // a fabricated `waitedMs` is invisible to any test with a fake clock in
        // it — the constant and the clock agree by construction there.
        //
        // One look at this window costs 3.2 s against a 2.5 s budget, which is
        // what a 1114-element Finder window really costs. The executor that
        // shipped reported `reason: "ceiling"` and `waitedMs: 2500` for it while
        // the call really took 3.25 s.
        let element = hostTestElement()
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]
        environment.focused = element
        let probe = SettleCostProbe(log: environment.keyEvents, costPerLook: 3.2)
        environment.probe = probe

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        let snapshot = hostTestSnapshot(
            registry: harness.server.currentRegistry(),
            session: "s1",
            element: element
        )
        harness.install(snapshot)

        let started = Date()
        harness.send(
            dispatchKey(
                snapshot: snapshot,
                action: #"{"kind":"key","key":"p","modifiers":["command"]}"#,
                settle: "quiesce"
            )
        )
        let result = try harness.awaitResult(timeout: 30)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        let settle = try XCTUnwrap(result["settle"] as? [String: Any])
        let waitedMs = try XCTUnwrap(settle["waitedMs"] as? Int)

        XCTAssertEqual(settle["reason"] as? String, "window_too_slow")
        XCTAssertEqual(settle["quiesced"] as? Bool, false)
        XCTAssertEqual(probe.looksTaken, 1)
        XCTAssertLessThanOrEqual(
            abs(waitedMs - elapsedMs),
            400,
            "waitedMs (\(waitedMs)) must be the time this call spent (\(elapsedMs)), not a constant"
        )
        XCTAssertGreaterThan(
            waitedMs,
            HostLimits().settleCeilingMs,
            "this settle overran the budget by one look and the wire has to say so"
        )
    }

    // MARK: - Launching an app (§5.7)

    func testAppsLaunchResolvesWithinTheBudgetTheCallerDeclared() throws {
        // §5.7 vector 43 — `waitForWindowMs` covers the whole of "make this app
        // usable". The executor used to resolve on a hardcoded five seconds and
        // apply the caller's budget only to the window wait, so a cold launch
        // that the host had allowed eight seconds for was refused at 5571 ms —
        // after the app had, in fact, started.
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"apps.launch","params":{"session":"s1","app":"Notes","waitForWindowMs":8000}}"#)

        let result = try harness.awaitResult()
        XCTAssertEqual(result["appId"] as? String, hostTestAppId)
        let requested = try XCTUnwrap(harness.environment.launches.requests.last)
        XCTAssertEqual(requested.query, "Notes")
        XCTAssertEqual(requested.budget, 8.0, accuracy: 0.001)

        // A caller that declares nothing keeps the behaviour it always had.
        var bare = FakeEnvironment()
        bare.windows = [hostTestWindow()]
        let unbudgeted = ServerHarness(environment: bare)
        try unbudgeted.begin()
        unbudgeted.send(#"{"jsonrpc":"2.0","id":3,"method":"apps.launch","params":{"session":"s1","app":"Notes"}}"#)
        _ = try unbudgeted.awaitResult()

        XCTAssertEqual(
            try XCTUnwrap(unbudgeted.environment.launches.requests.last).budget,
            AppDiscovery.defaultLaunchWaitSeconds,
            accuracy: 0.001
        )
    }

    func testAnAppThatIsStillStartingIsATimeoutNotAMissingApp() throws {
        // §5.7 vector 44 — the app exists, was told to start, and did not
        // register in time. `app_not_found` means "there is no such app" and
        // sends the model off to guess other names for an app that is already
        // launching; `timeout` says wait or look again.
        let started = Date()
        let budget: TimeInterval = 0.3

        XCTAssertThrowsError(
            try AppDiscovery.resolve(
                "Some Editor",
                waitFor: budget,
                launch: { _ in true },
                runningApps: { [] }
            )
        ) { error in
            guard case ComputerUseError.timeout = error else {
                return XCTFail("a launched app that did not appear is a timeout, not \(error)")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, budget, "the declared budget is waited out, not cut short")
        XCTAssertLessThan(elapsed, AppDiscovery.defaultLaunchWaitSeconds, "and the default no longer overrides it")

        // And it reaches the caller as `timeout` on the wire.
        var environment = FakeEnvironment()
        environment.launches.outcome = .failure(HostDomainError(.timeout))
        let harness = ServerHarness(environment: environment)
        try harness.begin()
        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"apps.launch","params":{"session":"s1","app":"TextEdit","waitForWindowMs":8000}}"#)

        XCTAssertEqual(try errorCode(try harness.awaitResult()), "timeout")
    }

    func testAnAppThatIsNowhereOnDiskIsAppNotFoundWithoutSpendingTheBudget() throws {
        // §5.7 vector 44, the other half — nothing answers to the name, so no
        // amount of waiting will change the answer and none is spent.
        let started = Date()

        XCTAssertThrowsError(
            try AppDiscovery.resolve(
                "Nothing By This Name",
                waitFor: 5,
                launch: { _ in false },
                runningApps: { [] }
            )
        ) { error in
            guard case ComputerUseError.appNotFound = error else {
                return XCTFail("an app that does not exist is app_not_found, not \(error)")
            }
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testABlockedAppIsRefusedRatherThanReportedMissing() throws {
        // §5.7 vector 45 — the handler used to reach the resolver through a
        // `try?`, which turned every failure into `app_not_found`, including the
        // safety list. "There is no such app" is false and actionable: the model
        // retries with another spelling of a password manager that is right there.
        XCTAssertThrowsError(try AppDiscovery.resolve("com.1password.1password", waitFor: 0)) { error in
            guard case ComputerUseError.permissionDenied = error else {
                return XCTFail("a blocked app is a refusal, not \(error)")
            }
        }

        XCTAssertEqual(hostAppLaunchFailure(ComputerUseError.permissionDenied("blocked")).code, .unsupportedAction)
        XCTAssertEqual(hostAppLaunchFailure(ComputerUseError.appNotFound("Nope")).code, .appNotFound)
        XCTAssertEqual(hostAppLaunchFailure(ComputerUseError.timeout("slow")).code, .timeout)
        // The system refused the launch itself: attempted, did not happen — and
        // still not a missing app.
        XCTAssertEqual(
            hostAppLaunchFailure(NSError(domain: NSCocoaErrorDomain, code: 260)).code,
            .dispatchRefused
        )
    }

    func testALaunchIsAskedForWithoutActivationAndWithoutTouchingRecentItems() throws {
        // §5.7 vector 50 — the request half. `NSWorkspace.OpenConfiguration` is
        // `activates = true` out of the box, so the executor that built one and
        // passed it unmodified asked for the user's foreground on every launch
        // and got it: a cold Preview was frontmost before the call returned.
        //
        // Asserted on the configuration rather than on its effect because the
        // effect needs a cold application on a desktop nobody else is touching;
        // that is `HostLaunchLiveTests`. Here the question is only whether the
        // executor asked, and the answer used to be no.
        let configuration = AppDiscovery.backgroundLaunchConfiguration()

        XCTAssertFalse(configuration.activates, "apps.launch must not ask for the foreground")
        XCTAssertFalse(
            configuration.addsToRecentItems,
            "a launch the model made is not something the user opened"
        )

        // The default is the thing being overridden, so a change of default is
        // not allowed to make this test vacuous.
        let untouched = NSWorkspace.OpenConfiguration()
        XCTAssertTrue(
            untouched.activates,
            "the default still activates, which is why the override has to exist"
        )
    }

    func testAnAppThatActivatesItselfIsStillReportedAsTakingTheForeground() throws {
        // §5.7 vector 50, the honesty half. The executor asks for a background
        // launch, and an application that calls `activateIgnoringOtherApps` on
        // its way up takes the foreground regardless. `foregroundTaken` is the
        // difference between two reads of the window server, never a restatement
        // of what the executor requested — an executor that answered `false`
        // because it had asked politely would report its own intent as an
        // observation, and the user's stolen focus would be invisible.
        XCTAssertFalse(AppDiscovery.backgroundLaunchConfiguration().activates)

        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]
        environment.frontmost.sequence = [1679, hostTestPid]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"apps.launch","params":{"session":"s1","app":"Preview","waitForWindowMs":8000}}"#)

        let result = try harness.awaitResult()
        XCTAssertEqual(result["ok"] as? Bool, true, "it happened; hiding it does not un-happen it")
        XCTAssertEqual(result["foregroundTaken"] as? Bool, true)
        XCTAssertEqual(harness.environment.frontmost.reads, 2, "before and after, not once")
    }

    // MARK: - Trusted target resolution (§5.2)

    func testTargetResolveFreezesRunningWindowAndProcessGeneration() throws {
        var environment = FakeEnvironment()
        environment.apps = [
            HostRunningApp(
                appId: hostTestAppId,
                pid: hostTestPid,
                name: "Fixture",
                running: true
            )
        ]
        environment.windows = [hostTestWindow()]
        environment.processStartTimes[hostTestPid] = hostTestProcessStartTime
        let harness = ServerHarness(environment: environment)
        try harness.begin()

        harness.send(#"{"jsonrpc":"2.0","id":10,"method":"target.resolve","params":{"target":{"kind":"window","windowId":7}}}"#)
        let result = try harness.awaitResult()
        XCTAssertEqual(result["resolution"] as? String, "resolved")
        let target = try XCTUnwrap(result["target"] as? [String: Any])
        XCTAssertEqual(target["kind"] as? String, "running")
        XCTAssertEqual(target["appId"] as? String, hostTestAppId)
        XCTAssertEqual(target["pid"] as? Int, Int(hostTestPid))
        XCTAssertEqual(
            target["processGeneration"] as? String,
            hostProcessGeneration(hostTestProcessStartTime)
        )
        XCTAssertEqual(target["windowId"] as? Int, 7)
    }

    func testTargetResolveDoesNotLaunchInstalledApplication() throws {
        var environment = FakeEnvironment()
        environment.installedBundleIds = ["com.apple.TextEdit"]
        let harness = ServerHarness(environment: environment)
        try harness.begin()

        harness.send(#"{"jsonrpc":"2.0","id":11,"method":"target.resolve","params":{"target":{"kind":"application","app":"TextEdit","intent":"launch"}}}"#)
        let result = try harness.awaitResult()
        XCTAssertEqual(result["resolution"] as? String, "resolved")
        XCTAssertEqual((result["target"] as? [String: Any])?["kind"] as? String, "installed")
        XCTAssertEqual(environment.launches.requests.count, 0)
    }

    func testObserveRejectsNonCanonicalProcessGeneration() throws {
        let harness = ServerHarness()
        try harness.begin()

        harness.send(#"{"jsonrpc":"2.0","id":12,"method":"observe","params":{"session":"s1","target":{"kind":"window","appId":"com.apple.TextEdit","pid":42,"processGeneration":"pst:01","windowId":7}}}"#)
        let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    // MARK: - Seeing the machine change (§5.5, §5.7)

    func testTheApplicationListIsAskedOfTheMachineOnEveryCall() throws {
        // §5.5 vector 46 — the executor outlives the applications it lists. An
        // application that starts after the executor did MUST appear in the next
        // `apps.list`, and the one thing that makes it not appear is answering
        // from a list read once.
        //
        // Measured on a real machine before this was fixed: 91 applications at
        // executor start, TextEdit started externally and confirmed with
        // `pgrep`, 91 applications and no TextEdit on every later call for the
        // life of the process.
        let environment = FakeEnvironment()
        environment.apps = [HostRunningApp(appId: hostTestAppId, pid: hostTestPid, name: "Notes", running: true)]

        let harness = ServerHarness(environment: environment)
        try harness.begin()

        harness.send(#"{"jsonrpc":"2.0","id":10,"method":"apps.list","params":{"session":"s1"}}"#)
        let before = try harness.awaitResult()
        XCTAssertEqual((before["apps"] as? [[String: Any]])?.count, 1)

        // The user starts TextEdit while the executor is running.
        environment.apps.append(
            HostRunningApp(appId: "com.apple.TextEdit", pid: 5150, name: "TextEdit", running: true)
        )

        harness.send(#"{"jsonrpc":"2.0","id":11,"method":"apps.list","params":{"session":"s1"}}"#)
        let after = try XCTUnwrap(try harness.awaitResult()["apps"] as? [[String: Any]])
        XCTAssertEqual(after.count, 2, "an application that started after the executor did is still an application")
        XCTAssertTrue(
            after.contains { $0["appId"] as? String == "com.apple.TextEdit" },
            "apps.list answered from a world that ended before the app existed"
        )
        XCTAssertEqual(harness.environment.inventory.reads, 2, "and it asked the machine both times")
    }

    func testAnApplicationThatRegistersDuringTheWaitIsResolved() throws {
        // §5.7 vector 46, the launch half — the poll re-reads the list, so an
        // application that registers part-way through the budget resolves. This
        // is the arm the real machine could never reach: the launch succeeded,
        // the process was up at 4990 ms, and the poll searched a list that could
        // not contain it, so an eight-second budget was spent in full and
        // answered `timeout`.
        var polls = 0
        let appeared = RunningAppDescriptor(
            name: "Some Editor",
            bundleIdentifier: "com.example.someeditor",
            pid: NSRunningApplication.current.processIdentifier,
            runningApplication: NSRunningApplication.current
        )

        let resolved = try AppDiscovery.resolve(
            "Some Editor",
            waitFor: 5,
            launch: { _ in true },
            runningApps: {
                polls += 1
                return polls < 3 ? [] : [appeared]
            }
        )

        XCTAssertEqual(resolved.name, "Some Editor")
        XCTAssertGreaterThanOrEqual(polls, 3, "the list is re-read while waiting, not read once and re-searched")
    }

    func testTheFrontmostApplicationIsReadOnBothSidesOfALaunch() throws {
        // §5.7 — `foregroundTaken` is a difference between two reads. Answering
        // both from one cached value makes it constant, and the constant it was
        // stuck at is `false`: an executor that took the user's foreground
        // reported that it had not.
        var environment = FakeEnvironment()
        environment.windows = [hostTestWindow()]
        environment.frontmost.sequence = [nil, hostTestPid]

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"apps.launch","params":{"session":"s1","app":"Notes"}}"#)

        let taken = try harness.awaitResult()
        XCTAssertEqual(taken["foregroundTaken"] as? Bool, true)
        XCTAssertEqual(harness.environment.frontmost.reads, 2, "before and after, not once")

        // An app that already held the foreground did not take it.
        var held = FakeEnvironment()
        held.windows = [hostTestWindow()]
        held.frontmost.sequence = [hostTestPid, hostTestPid]
        let unchanged = ServerHarness(environment: held)
        try unchanged.begin()
        unchanged.send(#"{"jsonrpc":"2.0","id":3,"method":"apps.launch","params":{"session":"s1","app":"Notes"}}"#)

        XCTAssertEqual(try unchanged.awaitResult()["foregroundTaken"] as? Bool, false)
    }

    func testTheFrontmostApplicationSortsFirstWithoutConsultingIsActive() throws {
        // The list used to be ordered by `NSRunningApplication.isActive`, which
        // comes off the same frozen cache as the list itself. The window server's
        // answer is what orders it now, and the ordering is the observable part.
        //
        // Real instances, because `NSRunningApplication` has no constructible
        // form: whichever of two applications is declared frontmost sorts first,
        // in both directions, so a comparator that fell back on `isActive` — a
        // property neither of these has set — fails one of the two.
        let applications = LiveApplicationInventory.runningApplications()
        try XCTSkipIf(applications.count < 2, "needs two running applications to order")

        let first = applications[0]
        let second = applications[1]

        XCTAssertEqual(
            AppDiscovery.runningApps(applications: { [first, second] }, frontmostPid: { first.processIdentifier })
                .first?.pid,
            first.processIdentifier
        )
        XCTAssertEqual(
            AppDiscovery.runningApps(applications: { [first, second] }, frontmostPid: { second.processIdentifier })
                .first?.pid,
            second.processIdentifier
        )
    }

    func testTheLiveInventoryIsReadFromTheKernelRatherThanAppKitsCache() {
        // The enumeration is a syscall, so the process running this test is in
        // it by construction. If this ever fails the buffer handling in
        // `processIdentifiers()` is wrong, and everything above it is guessing.
        let pids = LiveApplicationInventory.processIdentifiers()
        XCTAssertGreaterThan(pids.count, 1)
        XCTAssertTrue(pids.contains(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(pids.contains(0), "pid 0 is the kernel, not an application")
    }

    /// The mutation the seams above cannot make: a real application, started
    /// after this process, read from a thread that is not the main one while the
    /// main thread does not run a run loop — which is the only shape in which the
    /// defect appears. `NSWorkspace` answers this correctly on the main thread,
    /// so a test that stayed there would have passed against the broken executor;
    /// so would one that parked on `wait(for:)`, because that spins the main run
    /// loop and the spin is what thaws the cache. The main thread waits on a
    /// semaphore here for the same reason the executor's does: `readLine` does
    /// not spin anything either.
    ///
    /// Opt-in because it starts and stops TextEdit on the machine running it.
    func testAnApplicationStartedAfterThisProcessIsVisibleFromALane() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_APP_INVENTORY_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_APP_INVENTORY_LIVE_TEST=1 to run the live application inventory test")
        }

        func quitTextEdit() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \"TextEdit\" to quit"]
            try? process.run()
            process.waitUntilExit()
        }

        func textEditIsRunning() -> Bool {
            LiveApplicationInventory.runningApplications()
                .contains { $0.bundleIdentifier == "com.apple.TextEdit" }
        }

        addTeardownBlock { quitTextEdit() }

        // Warm whatever AppKit warms at first touch, so the difference under test
        // is the staleness and not the initialisation.
        _ = NSWorkspace.shared.runningApplications
        quitTextEdit()
        Thread.sleep(forTimeInterval: 2)

        let finished = DispatchSemaphore(value: 0)
        var sawItBefore = true
        var sawItAfter = false

        Thread.detachNewThread {
            sawItBefore = textEditIsRunning()

            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launch.arguments = ["-g", "-a", "TextEdit"]
            try? launch.run()
            launch.waitUntilExit()
            Thread.sleep(forTimeInterval: 6)

            sawItAfter = textEditIsRunning()
            finished.signal()
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)
        XCTAssertFalse(sawItBefore, "TextEdit had to be stopped for this to prove anything")
        XCTAssertTrue(sawItAfter, "the executor cannot see an application it did not start before itself")
    }

    // MARK: - Helpers

    private var nextRequestId = 300

    private func dispatchKey(
        snapshot: HostSnapshot,
        focusPolicy: String? = nil,
        action: String = #"{"kind":"type","text":"hello"}"#,
        settle: String? = nil
    ) -> String {
        nextRequestId += 1
        let element = snapshot.payload.elements[0]
        let policy = focusPolicy.map { ",\"focusPolicy\":\"\($0)\"" } ?? ""
        let observeAfter = settle.map { ",\"observeAfter\":{\"includeImage\":false,\"settle\":\"\($0)\"}" } ?? ""
        return """
        {"jsonrpc":"2.0","id":\(nextRequestId),"method":"dispatch.key","params":{\
        "session":"s1","snapshotId":"\(snapshot.id)","toolCallId":"call_4",\
        "focusToken":"\(element.token)","expectElementDigest":"\(element.digest)"\(policy),\
        "action":\(action)\(observeAfter)}}
        """
    }

    /// One settle against a window that costs `costPerLook` to look at, on a
    /// clock that moves only when this test says a look or a wait happened. The
    /// production loop is the thing under test; only the machine is fake.
    private func drivenSettle(
        costPerLook: TimeInterval,
        stable: Bool,
        ceilingMs: Int = HostLimits().settleCeilingMs
    ) -> (report: HostSettleReport, digest: String, looks: Int) {
        let clock = ManualClock()
        var looks = 0
        let settled = hostSettle(
            ceilingMs: ceilingMs,
            pollMs: hostSettlePollMs,
            sample: {
                looks += 1
                clock.advance(costPerLook)
                return stable ? "sha256:still" : "sha256:frame-\(looks)"
            },
            now: clock.read,
            sleep: clock.advance
        )

        return (settled.report, settled.digest, looks)
    }

    private func errorCode(_ result: [String: Any]) throws -> String {
        try XCTUnwrap((result["error"] as? [String: Any])?["code"] as? String)
    }

    private func makeRegistry() -> HostSnapshotRegistry {
        HostSnapshotRegistry(limits: HostLimits()) { _ in }
    }

    private func failureCode<Success>(_ result: Result<Success, HostDomainError>) -> HostDomainErrorCode? {
        guard case .failure(let error) = result else {
            return nil
        }
        return error.code
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
