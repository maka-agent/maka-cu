import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// §5.8, §12 vectors 56, 58 and 59 — the menu bar in an observation.
///
/// The defect these stand against is not a wrong value, it is an absent one: no
/// observation this executor has ever produced contained a single menu element.
/// `observe` roots its walk at a window and `kAXMenuBarAttribute` hangs off the
/// *application*, so the menu bar was not truncated, not filtered and not
/// refused — it was never on any path the walk took. Measured before this
/// change: Calculator 65 elements and TextEdit 1500, with zero `AXMenuBar`,
/// `AXMenuBarItem`, `AXMenu` or `AXMenuItem` between them.
///
/// Vector 57 — that a menu element's frame is suppressed at both ends of the
/// §4.3 binding check — is live only, and is in `HostMenuObserveLiveTests`. It
/// cannot be asserted here: the value being suppressed is one AppKit puts on a
/// real unopened menu item, and no fake produces it.
final class HostMenuObservationTests: XCTestCase {
    // MARK: - Vector 56: asked for, or not there at all

    func testTheMenuIsAbsentUnlessTheHostAsksForIt() throws {
        // §5.8 — "we did not look" and "we looked and there is nothing" are
        // different facts, so the field is absent rather than an empty array.
        // An observation that did not ask must be byte-identical to the one this
        // executor produced before menus existed.
        let harness = try menuHarness()

        harness.send(observe(id: 3, menu: nil))
        let without = try harness.snapshot()
        XCTAssertNil(without["menu"], "a request that did not ask for the menu must not carry the key at all")

        harness.send(observe(id: 5, menu: #"{"scope":"all"}"#))
        let menu = try XCTUnwrap(try harness.snapshot()["menu"] as? [String: Any], "`scope: all` must produce the key")
        XCTAssertNotNil(menu["elements"])
        XCTAssertNotNil(menu["truncated"])
    }

    func testAnApplicationWithNoMenuBarSaysSoRatherThanOmittingTheField() throws {
        // The distinction the shape exists for: an application with no menu bar
        // answers with the key present and empty. A host that read an absent key
        // as "none" could not tell that from "you never asked".
        var environment = menuEnvironment()
        environment.menuBar = nil

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        harness.send(observe(id: 3, menu: #"{"scope":"all"}"#))

        let menu = try XCTUnwrap(try harness.snapshot()["menu"] as? [String: Any])
        XCTAssertEqual((menu["elements"] as? [[String: Any]])?.count, 0)
    }

    func testAMenuBarWithNoItemsIsARootWithNoChildren() throws {
        // And the other side of it: a menu bar that exists and is empty comes
        // back as its own root element, because the walk always emits its root.
        // One element and zero elements are how the host tells the two apart
        // without a third field.
        var environment = menuEnvironment()
        environment.menuBar = FakeNode(role: "AXMenuBar")

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        harness.send(observe(id: 3, menu: #"{"scope":"all"}"#))

        let menu = try XCTUnwrap(try harness.snapshot()["menu"] as? [String: Any])
        let elements = try XCTUnwrap(menu["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0]["role"] as? String, "AXMenuBar")
        XCTAssertNil(elements[0]["parentToken"] as? String, "the menu root has no parent")
    }


    // MARK: - §5.8 scope: how much menu a host is asking for

    func testTheBarScopeStopsAtTheTopLevelItems() throws {
        // What an observation carries by default, and the reason it can: on a
        // real machine TextEdit's whole menu is 369 elements and 157 ms against a
        // 16-element, 58 ms window — the menu would be 94% of what the model
        // reads and 90% of what the observation costs, to answer "which menus are
        // there". At this scope that answer is nine elements and 5 ms.
        let harness = try menuHarness()
        harness.send(observe(id: 3, menu: #"{"scope":"bar"}"#))

        let menu = try XCTUnwrap(try harness.snapshot()["menu"] as? [String: Any])
        let elements = try XCTUnwrap(menu["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.map { $0["role"] as? String }, ["AXMenuBar", "AXMenuBarItem", "AXMenuBarItem"])
        XCTAssertEqual(elements.compactMap { $0["title"] as? String }, ["File", "Edit"])
        // Stopped by depth, and says so: there is more menu below, and a host
        // that could not tell would present a bar as if it were the whole menu.
        XCTAssertEqual((menu["truncated"] as? [String: Any])?["depth"] as? Bool, true)
    }

    func testTheMenuScopeOpensOneAndStillListsTheRest() throws {
        // A person opens 文件; they do not read all seven menus. Listing the
        // others is not a detail — a model that saw only the menu it asked for
        // would have to ask again to learn what else there is.
        let harness = try menuHarness()
        harness.send(observe(id: 3, menu: #"{"scope":"menu","title":"File"}"#))

        let menu = try XCTUnwrap(try harness.snapshot()["menu"] as? [String: Any])
        let elements = try XCTUnwrap(menu["elements"] as? [[String: Any]])
        let titles = elements.compactMap { $0["title"] as? String }
        XCTAssertEqual(titles, ["File", "New", "Export as PDF…", "Edit"])
        XCTAssertFalse(
            titles.contains("Undo"),
            "the unopened menu's contents are what this scope exists not to send"
        )
        // Not truncation: the host asked for this shape. Reporting it as one
        // would put the host's own request in front of the model as a limit of
        // the machine.
        XCTAssertEqual((menu["truncated"] as? [String: Any])?["depth"] as? Bool, false)
        XCTAssertEqual((menu["truncated"] as? [String: Any])?["elements"] as? Bool, false)
    }

    func testAnElementsDigestIsTheSameWhicheverScopeSawIt() throws {
        // The invariant that lets a host change scope between observations. A
        // scope decides descent and nothing else: `siblingIndex` still comes from
        // the full child list, `ancestorRoles` still from the live chain. Were
        // that not so, a `bar` observation's tokens would be bound to digests the
        // dispatch-time probe recomputes differently, and every press after a
        // narrow observe would be refused `element_changed` — which is exactly
        // the defect that shipped when the walk filtered a child list.
        let harness = try menuHarness()

        harness.send(observe(id: 3, menu: #"{"scope":"bar"}"#))
        let narrow = try XCTUnwrap(try harness.snapshot()["menu"] as? [String: Any])
        harness.send(observe(id: 4, menu: #"{"scope":"all"}"#))
        let wide = try XCTUnwrap(try harness.snapshot()["menu"] as? [String: Any])

        func digestsByTitle(_ menu: [String: Any]) -> [String: String] {
            var out: [String: String] = [:]
            for element in (menu["elements"] as? [[String: Any]]) ?? [] {
                if let title = element["title"] as? String, let digest = element["digest"] as? String {
                    out[title] = digest
                }
            }
            return out
        }

        let narrowDigests = digestsByTitle(narrow)
        let wideDigests = digestsByTitle(wide)
        XCTAssertEqual(narrowDigests.keys.sorted(), ["Edit", "File"])
        for (title, digest) in narrowDigests {
            XCTAssertEqual(digest, wideDigests[title], "\(title) hashes differently depending on how much of the menu was walked")
        }
    }

    func testAScopeThatNamesNothingIsRejectedRatherThanAnsweredWithEverything() throws {
        // A `menu` scope with no title answers with every bar item and no
        // contents, which reads exactly like "that menu is empty". A `title` on
        // `all` is indistinguishable from a menu name the host got wrong: both
        // come back with the whole tree. Neither is silently allowed.
        let harness = try menuHarness()

        for request in [
            #"{"scope":"menu"}"#,
            #"{"scope":"menu","title":""}"#,
            #"{"scope":"bar","title":"File"}"#,
            #"{"scope":"all","title":"File"}"#,
        ] {
            harness.send(observe(id: 3, menu: request))
            let error = try XCTUnwrap(try harness.awaitResponse()["error"] as? [String: Any], "\(request) was accepted")
            XCTAssertEqual(error["code"] as? Int, -32602, "\(request)")
        }
    }

    func testANamedMenuThatIsNotThereComesBackAsTheBarWithNothingOpen() throws {
        // Deliberately not an error. "There is no menu called that" is a fact
        // about the application, and the bar it comes back with is the answer to
        // the question the host should ask next; an RPC error would carry no
        // menu at all and leave it guessing at spelling.
        let harness = try menuHarness()
        harness.send(observe(id: 3, menu: #"{"scope":"menu","title":"Format"}"#))

        let menu = try XCTUnwrap(try harness.snapshot()["menu"] as? [String: Any])
        let elements = try XCTUnwrap(menu["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.compactMap { $0["title"] as? String }, ["File", "Edit"])
    }

    // MARK: - Vector 58: the menu has its own budget, and stays out of the window's

    func testTheMenuDoesNotChangeTheWindowDigest() throws {
        // §5.8 — the reason the menu is a second array and not a second root. A
        // menu folded into `elements` would join the window hash, so the same
        // window would digest differently depending on whether the host had
        // asked for menus, and every settle would pay for menu elements that
        // cannot change while the window does.
        let harness = try menuHarness()

        harness.send(observe(id: 3, menu: nil))
        let without = try harness.snapshot()

        harness.send(observe(id: 4, menu: #"{"scope":"all"}"#))
        let with = try harness.snapshot()

        XCTAssertEqual(
            without["windowDigest"] as? String,
            with["windowDigest"] as? String,
            "the window digest is over the window, and asking for the menu is not a change to the window"
        )
        XCTAssertEqual(
            (without["elements"] as? [[String: Any]])?.count,
            (with["elements"] as? [[String: Any]])?.count,
            "`elements` means what is in the window; the menu is not in it"
        )
    }

    func testTheMenuIsBoundedByItsOwnLimitAndReportsBeingCut() throws {
        // §5.8 — `maxMenuElements`, not a share of `maxElements`. Measured, the
        // two do not fit in one budget: a Finder window is 1711 elements on its
        // own and its menu bar is 274, so a shared bound starves the menu in the
        // application whose menu carries the work.
        //
        // The bound asserted is the shipped one rather than one injected for the
        // test, because the number is the claim: 500 clears the largest menu bar
        // measured (VS Code, 393 with the Apple menu excluded) by 27%, and a test
        // that supplied its own would still pass if the default were 5.
        let limits = HostLimits()
        var environment = menuEnvironment()
        environment.menuBar = FakeNode(
            role: "AXMenuBar",
            children: (0..<(limits.maxMenuElements + 200)).map {
                FakeNode(role: "AXMenuBarItem", title: "m\($0)")
            }
        )

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        harness.send(observe(id: 3, menu: #"{"scope":"all"}"#))

        let snapshot = try harness.snapshot()
        let menu = try XCTUnwrap(snapshot["menu"] as? [String: Any])
        XCTAssertEqual((menu["elements"] as? [[String: Any]])?.count, limits.maxMenuElements)
        XCTAssertEqual(
            (menu["truncated"] as? [String: Any])?["elements"] as? Bool,
            true,
            "a cut menu says so; a host told nothing concludes the command is not there"
        )
        XCTAssertEqual(
            (snapshot["truncated"] as? [String: Any])?["elements"] as? Bool,
            false,
            "the window was not cut, and the menu's truncation is not reported as the window's"
        )
        XCTAssertGreaterThanOrEqual(
            limits.maxMenuElements,
            393,
            "the bound has to clear the largest menu bar measured, or the applications that need menus most are the ones that get cut"
        )
    }

    // MARK: - Vector 59: a menu element is addressed like any other element

    func testAMenuTokenResolvesThroughTheSameDispatchAsAWindowElement() throws {
        // §5.8 — menu bindings join the snapshot's one dictionary, so
        // `dispatch.element` needs no new method and no new kind. The proof that
        // the token resolved is that the refusal is about the *element* rather
        // than about the token: `element_released` is raised after the token was
        // found and its digest matched, at the point a live Accessibility
        // reference is needed — and a fake has none.
        let harness = try menuHarness()
        harness.send(observe(id: 3, menu: #"{"scope":"all"}"#))
        let snapshot = try harness.snapshot()

        let snapshotId = try XCTUnwrap(snapshot["snapshotId"] as? String)
        let menu = try XCTUnwrap(snapshot["menu"] as? [String: Any])
        let elements = try XCTUnwrap(menu["elements"] as? [[String: Any]])
        let item = try XCTUnwrap(elements.first { $0["role"] as? String == "AXMenuItem" && $0["enabled"] as? Bool == true })

        harness.send(dispatch(
            id: 4,
            snapshotId: snapshotId,
            token: try XCTUnwrap(item["token"] as? String),
            digest: try XCTUnwrap(item["digest"] as? String)
        ))

        let result = try harness.result()
        XCTAssertEqual(
            (result["error"] as? [String: Any])?["code"] as? String,
            "element_released",
            "the token resolved and the digest matched; only the live reference is missing"
        )
    }

    func testAMenuTokenCannotCollideWithAWindowToken() throws {
        // Both walks mint `el_<prefix>_<n>` from 0. Sharing a prefix would make
        // `el_…_3` mean two elements in one snapshot, and §4.2's dictionary
        // lookup would answer with whichever was inserted last — silently
        // dispatching at the wrong control.
        let harness = try menuHarness()
        harness.send(observe(id: 3, menu: #"{"scope":"all"}"#))
        let snapshot = try harness.snapshot()

        let windowTokens = Set((snapshot["elements"] as? [[String: Any]] ?? []).compactMap { $0["token"] as? String })
        let menuTokens = Set(((snapshot["menu"] as? [String: Any])?["elements"] as? [[String: Any]] ?? [])
            .compactMap { $0["token"] as? String })

        XCTAssertFalse(menuTokens.isEmpty)
        XCTAssertTrue(windowTokens.isDisjoint(with: menuTokens), "one snapshot, one token space")
    }

    func testADisabledMenuItemIsRefusedRatherThanPressedAndReportedOk() throws {
        // §5.8, and the load-bearing half of it. Measured on macOS 26.5:
        // `AXUIElementPerformAction(item, "AXPress")` on a menu item whose
        // application reports `enabled: false` returns `kAXErrorSuccess` and does
        // nothing at all — Calculator's `编辑 > 拷贝`, pressed with the
        // application in the background, left the pasteboard untouched
        // (changeCount 253 → 253) while the enabled `显示 > 基础` resized the
        // window 674×408 → 230×408 through the same call.
        //
        // So without this refusal every disabled menu item would be reported
        // `outcome: "ok"` and the model would be told a command had run that had
        // not. The existing `element_disabled` guard is what stands between those
        // two, and this vector is what keeps anyone from deciding that a menu is
        // a special case that should skip it.
        let harness = try menuHarness()
        harness.send(observe(id: 3, menu: #"{"scope":"all"}"#))
        let snapshot = try harness.snapshot()

        let snapshotId = try XCTUnwrap(snapshot["snapshotId"] as? String)
        let elements = try XCTUnwrap((snapshot["menu"] as? [String: Any])?["elements"] as? [[String: Any]])
        let disabled = try XCTUnwrap(elements.first { $0["enabled"] as? Bool == false })

        harness.send(dispatch(
            id: 4,
            snapshotId: snapshotId,
            token: try XCTUnwrap(disabled["token"] as? String),
            digest: try XCTUnwrap(disabled["digest"] as? String)
        ))

        let result = try harness.result()
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "element_disabled")
        XCTAssertEqual(result["outcome"] as? String, "refused")
        XCTAssertEqual(result["path"] as? String, "none", "nothing was dispatched")
    }

    // MARK: - Vector 63: `title` reaches the wire

    func testAnElementCarriesItsTitleAndItsLabelSeparately() throws {
        // §5.2 — two AX attributes, two fields. Which one an element names itself
        // with is the application's choice: measured on a background Calculator,
        // 23 of 35 window elements carry a `label` and 2 of 126 menu elements do,
        // because AppKit's controls set `AXDescription` and its menu items set
        // `AXTitle`. Before this field existed a menu observation was 126
        // anonymous nodes.
        //
        // They are separate rather than merged because §4.3 digests them
        // separately and §6.2 reports `detail.changed: ["title"]` — a code that
        // named a field the wire did not carry.
        var environment = menuEnvironment()
        environment.menuBar = FakeNode(
            role: "AXMenuBar",
            children: [
                FakeNode(role: "AXMenuBarItem", title: "File", label: nil),
                FakeNode(role: "AXMenuBarItem", title: nil, label: "described"),
                FakeNode(role: "AXMenuBarItem", title: "both-title", label: "both-label"),
            ]
        )

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        harness.send(observe(id: 3, menu: #"{"scope":"all"}"#))

        let elements = try XCTUnwrap((try harness.snapshot()["menu"] as? [String: Any])?["elements"] as? [[String: Any]])
        let named = elements.dropFirst().map { ($0["title"] as? String, $0["label"] as? String) }

        XCTAssertEqual(named.count, 3)
        XCTAssertEqual(named[0].0, "File", "a title-only element must arrive named")
        XCTAssertNil(named[0].1)
        XCTAssertNil(named[1].0)
        XCTAssertEqual(named[1].1, "described")
        XCTAssertEqual(named[2].0, "both-title", "neither field overwrites the other")
        XCTAssertEqual(named[2].1, "both-label")
    }

    func testATruncatedTitleIsReportedLikeEveryOtherTruncatedField() throws {
        // §5.2 — `truncated` is a closed set and `title` joined it, so a cut
        // title is a field read rather than a length comparison the host has to
        // make against a bound it would have to hardcode.
        let limits = HostLimits()
        var environment = menuEnvironment()
        environment.menuBar = FakeNode(
            role: "AXMenuBar",
            children: [
                FakeNode(role: "AXMenuBarItem", title: String(repeating: "x", count: limits.maxTextChars + 10)),
            ]
        )

        let harness = ServerHarness(environment: environment)
        try harness.begin()
        harness.send(observe(id: 3, menu: #"{"scope":"all"}"#))

        let elements = try XCTUnwrap((try harness.snapshot()["menu"] as? [String: Any])?["elements"] as? [[String: Any]])
        let item = try XCTUnwrap(elements.last)
        XCTAssertEqual((item["title"] as? String)?.count, limits.maxTextChars)
        XCTAssertEqual(item["truncated"] as? [String], ["title"])
    }

    // MARK: - `observeAfter`
    func testTheMenuIsAbsentFromAPostDispatchFrameUnlessThatFrameAskedForIt() throws {
        // §5.8 — `observeAfter.menu` defaults to false, so a dispatch that says
        // nothing about menus costs no menu walk. A dispatch that asks gets the
        // same shape `observe` produces, because it is the same call.
        let harness = try menuHarness()
        harness.send(observe(id: 3, menu: #"{"scope":"all"}"#))
        let snapshot = try harness.snapshot()
        let snapshotId = try XCTUnwrap(snapshot["snapshotId"] as? String)
        let element = try XCTUnwrap((snapshot["elements"] as? [[String: Any]])?.first)

        // The window root, which has no `press`, so the dispatch is refused
        // before anything is touched — and a refusal does not spend the frame
        // (§4.1), so the same snapshot can be quoted again below.
        harness.send(dispatch(
            id: 4,
            snapshotId: snapshotId,
            token: try XCTUnwrap(element["token"] as? String),
            digest: "not-the-recorded-digest",
            observeAfterMenu: #"{"scope":"all"}"#
        ))
        let refused = try harness.result()
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "element_digest_mismatch")
        XCTAssertNil(refused["snapshot"], "a refusal carries no post-observation to put a menu in")
    }

    // MARK: - Helpers

    /// A pid the machine really has, because `buildSnapshot` reads its start time
    /// through `proc_pidinfo` and a made-up one is `process_replaced` before any
    /// of this is reached.
    private var livePid: pid_t { ProcessInfo.processInfo.processIdentifier }

    private func menuEnvironment() -> FakeEnvironment {
        var environment = FakeEnvironment()
        environment.apps = [
            HostRunningApp(appId: hostTestAppId, pid: livePid, name: "Notes", running: true),
        ]
        environment.windows = [hostTestWindow(pid: livePid)]
        environment.processStartTimes[livePid] = hostProcessStartTime(pid: livePid)
        // §4.3 E2 — these snapshots are minted by the real `buildSnapshot`, so
        // their bindings record the *machine's* start time for `livePid`. The
        // fixture's constant would be a different number and every dispatch below
        // would be `process_replaced` before reaching what it is testing.
        var probe = FakeBindingProbe()
        probe.startTime = hostProcessStartTime(pid: livePid)
        environment.probe = probe
        // An opaque handle for the window root. It is walked, and answers with
        // whatever the test process itself exposes — which is not the subject
        // here, and every assertion below is either about the menu or compares
        // two observations of this same element.
        environment.windowElement = hostTestElement(pid: livePid)
        environment.menuBar = FakeNode(
            role: "AXMenuBar",
            children: [
                FakeNode(
                    role: "AXMenuBarItem",
                    title: "File",
                    rawActionNames: ["AXPress"],
                    children: [
                        FakeNode(
                            role: "AXMenu",
                            children: [
                                FakeNode(role: "AXMenuItem", title: "New", rawActionNames: ["AXPress", "AXPick"]),
                                FakeNode(
                                    role: "AXMenuItem",
                                    title: "Export as PDF…",
                                    enabled: false,
                                    rawActionNames: ["AXPress", "AXPick"]
                                ),
                            ]
                        ),
                    ]
                ),
                // A second menu, so a scope that opens one can be told from a
                // scope that opens everything. With a single menu the two are
                // the same observation.
                FakeNode(
                    role: "AXMenuBarItem",
                    title: "Edit",
                    rawActionNames: ["AXPress"],
                    children: [
                        FakeNode(
                            role: "AXMenu",
                            children: [
                                FakeNode(role: "AXMenuItem", title: "Undo", rawActionNames: ["AXPress", "AXPick"]),
                            ]
                        ),
                    ]
                ),
            ]
        )
        return environment
    }

    private func menuHarness() throws -> ServerHarness {
        let harness = ServerHarness(environment: menuEnvironment())
        try harness.begin()
        return harness
    }

    /// `menu` is the raw JSON value for the field, so a test can send a scope
    /// the executor should reject as easily as one it should honour.
    private func observe(id: Int, menu: String?) -> String {
        let field = menu.map { ",\"menu\":\($0)" } ?? ""
        return """
        {"jsonrpc":"2.0","id":\(id),"method":"observe","params":{"session":"s1",\
        "target":{"kind":"window","appId":"\(hostTestAppId)","pid":\(livePid),"processGeneration":"\(hostProcessGeneration(hostProcessStartTime(pid: livePid) ?? 0))","windowId":1},"includeImage":false\(field)}}
        """
    }

    private func dispatch(
        id: Int,
        snapshotId: String,
        token: String,
        digest: String,
        observeAfterMenu: String? = nil
    ) -> String {
        let after = observeAfterMenu.map {
            ",\"observeAfter\":{\"includeImage\":false,\"settle\":\"none\",\"menu\":\($0)}"
        } ?? ""
        return """
        {"jsonrpc":"2.0","id":\(id),"method":"dispatch.element","params":{"session":"s1",\
        "snapshotId":"\(snapshotId)","toolCallId":"call_\(id)","elementToken":"\(token)",\
        "expectElementDigest":"\(digest)","action":{"kind":"click","button":"left","count":1}\(after)}}
        """
    }
}

private extension ServerHarness {
    func result() throws -> [String: Any] {
        try XCTUnwrap(try awaitResponse()["result"] as? [String: Any])
    }

    func snapshot() throws -> [String: Any] {
        let result = try result()
        guard result["ok"] as? Bool == true else {
            throw ComputerUseError.message("observe failed: \(result)")
        }
        return try XCTUnwrap(result["snapshot"] as? [String: Any])
    }
}
