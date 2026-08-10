import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

// Shared doubles for the `maka.cu/2` conformance vectors. Everything here stands
// in for the live machine so the §4 binding rules can be asserted without a
// desktop; nothing here fakes protocol logic.

/// A tree node with no Accessibility behind it.
final class FakeNode: HostAccessibilityNode {
    let role: String
    let subrole: String?
    let axIdentifier: String?
    let title: String?
    let label: String?
    let value: String?
    let placeholder: String?
    let enabled: Bool
    let focused: Bool
    let selected: Bool?
    let frameInWindow: CGRect?
    let rawActionNames: [String]
    /// What `AXParent` would answer for this node. `nil` is a node with nothing
    /// behind it, which is what most fixtures want; a test that needs the seam
    /// between the walk and the binding probe sets it, because that seam only
    /// exists for nodes whose chain is read live.
    let liveAncestorRoles: [String]?
    private let childNodes: [FakeNode]

    var axElement: AXUIElement? { nil }
    var children: [HostAccessibilityNode] { childNodes }

    init(
        role: String,
        subrole: String? = nil,
        axIdentifier: String? = nil,
        title: String? = nil,
        label: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        enabled: Bool = true,
        focused: Bool = false,
        selected: Bool? = nil,
        frameInWindow: CGRect? = nil,
        rawActionNames: [String] = [],
        liveAncestorRoles: [String]? = nil,
        children: [FakeNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.axIdentifier = axIdentifier
        self.title = title
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.frameInWindow = frameInWindow
        self.rawActionNames = rawActionNames
        self.liveAncestorRoles = liveAncestorRoles
        self.childNodes = children
    }
}

/// Answers E1–E3 from configured state. With no `override` it reports exactly
/// what the binding recorded, so a dispatch that should pass the binding check
/// does, and a test that expects a refusal has to say which check fails.
///
/// It answers from the *record*, which makes it blind by construction to the one
/// thing §4.3 actually rests on: whether the walk and the probe compute the same
/// inputs from the same unchanged element. `FakeRecomputingProbe` below is the
/// double for that.
struct FakeBindingProbe: HostElementBindingProbe {
    var alive = true
    var startTime: UInt64? = hostTestProcessStartTime
    var startTimes: [pid_t: UInt64] = [:]
    var actualPidOverride: pid_t?
    var override: HostElementDigestInput?
    var refetch: HostBindingRefetchResult = .missing
    var webContentEquivalent: HostElementBinding?

    init(override: HostElementDigestInput? = nil) {
        self.override = override
    }

    func isReferenceAlive(_ binding: HostElementBinding) -> Bool { alive }
    func processStartTime(pid: pid_t) -> UInt64? { startTimes[pid] ?? startTime }
    func actualPid(_ binding: HostElementBinding) -> pid_t? {
        actualPidOverride ?? binding.dispatchPid
    }
    func currentDigestInput(_ binding: HostElementBinding) -> HostElementDigestInput? {
        override ?? binding.digestInput
    }
    func uniqueRefetch(_ binding: HostElementBinding) -> HostBindingRefetchResult { refetch }
    func uniqueWebContentEquivalent(_ binding: HostElementBinding) -> HostElementBinding? {
        webContentEquivalent
    }
}

/// Recomputes the digest inputs the way `HostAXBindingProbe` does: from the node
/// as it is now, through `hostElementDigestInput`, with the live ancestor chain
/// and a live sibling index — and with no traversal to fall back on, because this
/// side reads one element rather than a tree.
///
/// The window under it is unchanged. Every refusal it produces is therefore a
/// disagreement between the two ends about how to read something that did not
/// move, which is the fault class this double exists to catch.
///
/// A reference type because the tokens it answers for are minted by the walk,
/// which needs the server's registry, which needs the environment holding this.
final class FakeRecomputingProbe: HostElementBindingProbe {
    /// The nodes as the machine would answer for them now, by token.
    var nodes: [String: FakeNode] = [:]
    /// What a live `AXParent` read would answer for each token's position. The
    /// root's entry is deliberately not its traversal index: a window's place in
    /// its application's `AXWindows` is z-order in many apps, and §4.3's root
    /// rule is what keeps that out of the digest.
    var siblingIndexes: [String: Int] = [:]

    func isReferenceAlive(_ binding: HostElementBinding) -> Bool { nodes[binding.token] != nil }
    func processStartTime(pid: pid_t) -> UInt64? { hostTestProcessStartTime }

    func currentDigestInput(_ binding: HostElementBinding) -> HostElementDigestInput? {
        guard let node = nodes[binding.token] else {
            return nil
        }

        return hostElementDigestInput(
            node: node,
            depth: binding.depth,
            actions: hostNormalizedActions(node.rawActionNames),
            ancestorRoles: node.liveAncestorRoles ?? [],
            siblingIndex: siblingIndexes[binding.token] ?? 0
        )
    }
}

/// Records what the executor asked the machine to do, so a test can assert that
/// a refusal posted nothing at all.
final class PointEventLog {
    private let lock = NSLock()
    private(set) var posted: [
        (action: HostPointAction, point: CGPoint, pid: pid_t, path: HostDispatchPath)
    ] = []
    /// When set, the post throws — the executor's "attempted, the OS said no".
    var failure: Error?

    func record(action: HostPointAction, point: CGPoint, pid: pid_t, path: HostDispatchPath) throws {
        lock.lock()
        posted.append((action: action, point: point, pid: pid, path: path))
        lock.unlock()

        if let failure {
            throw failure
        }
    }
}

/// Records what `dispatch.key` asked the machine to do about focus, and decides
/// what the machine does with it — so a test can tell "the executor never asked"
/// from "it asked and the element would not take focus".
final class FocusRequestLog {
    private let lock = NSLock()
    private var requests: [AXUIElement] = []
    private var granted: AXUIElement?

    /// The `kAXFocused` write itself is refused.
    var writeSucceeds = true
    /// The write is accepted *and* focus follows. `false` is the application that
    /// answers `AXError.success` and leaves focus where it was — the reason the
    /// executor re-reads instead of trusting the write.
    var focusFollows = true

    var requested: [AXUIElement] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var currentFocus: AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }

    func record(_ element: AXUIElement) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requests.append(element)

        guard writeSucceeds else {
            return false
        }

        if focusFollows {
            granted = element
        }
        return true
    }
}

/// Records the keys the executor posted, so a refusal can be asserted to have
/// posted nothing — and so a passing dispatch does not type into whatever real
/// process happens to hold the fixture pid.
final class KeyEventLog {
    private let lock = NSLock()
    private(set) var posted: [HostKeyAction] = []
    private(set) var postedPids: [pid_t] = []
    /// When set, the post throws — the executor's "attempted, the OS said no".
    var failure: Error?

    var hasPosted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !posted.isEmpty
    }

    func record(_ action: HostKeyAction, pid: pid_t = hostTestPid) throws {
        lock.lock()
        posted.append(action)
        postedPids.append(pid)
        lock.unlock()

        if let failure {
            throw failure
        }
    }
}

final class TextElementLog {
    var beforeValue: String?
    var afterValue: String?
    var selectAllSucceeds = true
    private(set) var selectAllCount = 0

    func value(afterKeyPosted: Bool) -> String? {
        afterKeyPosted ? afterValue : beforeValue
    }

    func selectAll() -> Bool {
        selectAllCount += 1
        return selectAllSucceeds
    }
}

/// A probe whose answer changes once a key has been posted, so a test can put a
/// real window delta on the other side of a dispatch.
///
/// `FakeBindingProbe` answers from the record and therefore recomputes the same
/// window digest for ever; no test built on it can tell an executor that judges
/// a key by the window from one that judges it by the focused element's value.
/// The element it answers for is unchanged until the key lands, so the binding
/// check ahead of the dispatch passes exactly as it does in production.
final class KeyReactiveProbe: HostElementBindingProbe {
    private let log: KeyEventLog
    /// What the element looks like after the key landed. `nil` is the window that
    /// does not change at all — the honest majority case, where the effect went
    /// to a sheet, another window, the menu bar or the file system.
    private let after: HostElementDigestInput?

    init(log: KeyEventLog, after: HostElementDigestInput? = nil) {
        self.log = log
        self.after = after
    }

    func isReferenceAlive(_ binding: HostElementBinding) -> Bool { true }
    func processStartTime(pid: pid_t) -> UInt64? { hostTestProcessStartTime }

    func currentDigestInput(_ binding: HostElementBinding) -> HostElementDigestInput? {
        guard let after, !log.posted.isEmpty else {
            return binding.digestInput
        }
        return after
    }
}

/// Records what `apps.launch` asked the resolver for, so a test can tell the
/// caller's declared budget from the executor's own default — the two were
/// indistinguishable while the handler resolved on a hardcoded five seconds.
final class AppLaunchLog {
    private let lock = NSLock()
    private(set) var requests: [(query: String, budget: TimeInterval)] = []
    /// What the machine answers. Defaults to the fixture app already running.
    var outcome: Result<HostRunningApp, HostDomainError> = .success(
        HostRunningApp(appId: hostTestAppId, pid: hostTestPid, name: "Notes", running: true)
    )

    func record(_ query: String, _ budget: TimeInterval) -> Result<HostRunningApp, HostDomainError> {
        lock.lock()
        requests.append((query: query, budget: budget))
        lock.unlock()
        return outcome
    }
}

/// The machine's application list, which changes while the executor is running.
///
/// A reference type so a test can start an application *after* the server has
/// already answered `apps.list` once, which is the shape of the defect it exists
/// to keep out: an executor that reads the list into a snapshot answers the
/// second call from the first call's world and can never see anything it
/// launched.
final class AppInventoryLog {
    private let lock = NSLock()
    private var stored: [HostRunningApp] = []
    private(set) var reads = 0

    var apps: [HostRunningApp] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func read() -> [HostRunningApp] {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return stored
    }
}

/// Which pid holds the foreground, read once per question rather than once per
/// process. `sequence` is what a test uses when the answer has to differ across
/// a single request — `apps.launch` asks before and after, and `foregroundTaken`
/// is the difference.
final class FrontmostApplicationLog {
    private let lock = NSLock()
    var pid: pid_t?
    var sequence: [pid_t?] = []
    private(set) var reads = 0
    private(set) var restoreRequests: [pid_t] = []
    var restoreSucceeds = true

    func read() -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        guard !sequence.isEmpty else {
            return pid
        }

        return sequence.removeFirst()
    }

    func restore(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        restoreRequests.append(pid)
        guard restoreSucceeds else {
            return false
        }
        self.pid = pid
        return true
    }
}

final class WindowElementLog {
    private let lock = NSLock()
    var fallback: AXUIElement?
    var sequence: [AXUIElement?] = []
    private(set) var reads = 0

    func read() -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        guard !sequence.isEmpty else {
            return fallback
        }
        return sequence.removeFirst()
    }
}

struct FakeEnvironment: HostSystemEnvironment {
    var locked = false
    var accessibilityTrusted = true
    var screenCaptureGranted = true
    var inventory = AppInventoryLog()
    var frontmost = FrontmostApplicationLog()
    var webContentPid: pid_t?
    var apps: [HostRunningApp] {
        get { inventory.apps }
        nonmutating set { inventory.apps = newValue }
    }
    var windows: [HostWindowInfo] = []
    var probe: HostElementBindingProbe = FakeBindingProbe()
    /// Left `nil` by default: most tests assert a refusal that happens before the
    /// element is touched. The `dispatch.key` vectors that need a real
    /// `AXUIElement` use `hostTestElement`.
    var focused: AXUIElement?
    var windowElements = WindowElementLog()
    var windowElement: AXUIElement? {
        get { windowElements.fallback }
        nonmutating set { windowElements.fallback = newValue }
    }
    /// §5.8 — the menu bar tree, or `nil` for an application with no menu bar.
    /// Left `nil` by default so an observation that did not ask for the menu is
    /// the same test it always was.
    var menuBar: FakeNode?
    var pointEvents = PointEventLog()
    var keyEvents = KeyEventLog()
    var textElement = TextElementLog()
    var focusRequests = FocusRequestLog()
    var launches = AppLaunchLog()

    func screenIsLocked() -> Bool { locked }

    func permissions() -> PermissionDiagnostics {
        PermissionDiagnostics(
            accessibilityTrusted: accessibilityTrusted,
            screenCaptureGranted: screenCaptureGranted
        )
    }

    func runningApps() -> [HostRunningApp] { inventory.read() }
    func frontmostApplicationPid() -> pid_t? { frontmost.read() }
    func restoreFrontmostApplication(pid: pid_t) -> Bool { frontmost.restore(pid) }
    func beginSyntheticTargetFocus(
        pid: pid_t,
        windowId: CGWindowID
    ) -> SkyLightSyntheticFocusContext? { nil }
    func endSyntheticTargetFocus(_ context: SkyLightSyntheticFocusContext) -> Bool { true }
    func webContentProcess(pid: pid_t) -> pid_t? { webContentPid }
    func onScreenWindows() -> [HostWindowInfo] { windows }

    func launchApp(_ query: String, waitFor budget: TimeInterval) -> Result<HostRunningApp, HostDomainError> {
        launches.record(query, budget)
    }

    func windowElement(pid: pid_t, windowId: CGWindowID, bounds: CGRect) -> AXUIElement? {
        windowElements.read()
    }
    func menuBarNode(pid: pid_t) -> HostAccessibilityNode? { menuBar }
    func focusedElement(pid: pid_t) -> AXUIElement? { focusRequests.currentFocus ?? focused }
    func setFocusedElement(_ element: AXUIElement, pid: pid_t) -> Bool { focusRequests.record(element) }
    func elementIsFocused(_ element: AXUIElement) -> Bool {
        focusRequests.currentFocus.map { CFEqual($0, element) } ?? false
    }
    func elementStringValue(_ element: AXUIElement) -> String? {
        textElement.value(afterKeyPosted: keyEvents.hasPosted)
    }
    func selectAllText(_ element: AXUIElement) -> Bool { textElement.selectAll() }
    func bindingProbe(windowBounds: CGRect) -> HostElementBindingProbe { probe }

    func postPointEvent(
        _ action: HostPointAction,
        at point: CGPoint,
        from start: CGPoint?,
        pid: pid_t,
        path: HostDispatchPath
    ) throws {
        try pointEvents.record(action: action, point: point, pid: pid, path: path)
    }

    func postKeyEvent(_ action: HostKeyAction, pid: pid_t) throws {
        try keyEvents.record(action, pid: pid)
    }

    func postWebContentClick(
        at screenPoint: CGPoint,
        windowPoint: CGPoint,
        window: HostWindowInfo,
        dispatchPid: pid_t,
        count: Int
    ) throws {
        try pointEvents.record(
            action: .leftClick(count: count),
            point: screenPoint,
            pid: dispatchPid,
            path: .skylightPid
        )
    }
}

/// A clock that moves by a fixed step every time it is read, so a walk's
/// deadline lands after a known number of nodes instead of after a real wait.
///
/// It exists because the windows that make `observe` run out of time are open
/// and save panels — every node of one crosses into
/// `com.apple.appkit.xpc.openAndSavePanelService` — and no test can put one on
/// the screen. Sleeping instead would make the suite slow and the boundary
/// fuzzy; this makes it exact.
final class SteppingClock: @unchecked Sendable {
    /// Fixed rather than `Date()`, so a failure reads the same on every machine.
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    private let step: TimeInterval
    private let lock = NSLock()
    private var reads = 0

    init(step: TimeInterval) {
        self.step = step
    }

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let now = start.addingTimeInterval(step * Double(reads))
        reads += 1
        return now
    }
}

/// A clock the test moves by hand, so a settle that would take seconds of real
/// time takes none and lands on an exact millisecond.
///
/// Hand-moved rather than stepping: `hostSettle` reads the clock several times
/// per round, and a clock that advanced on every read would make the number
/// under test a function of how many times the implementation happened to look
/// at it. Here the test says what each look at the window cost and what each
/// wait cost, and nothing else moves time at all.
final class ManualClock: @unchecked Sendable {
    /// Fixed rather than `Date()`, so a failure reads the same on every machine.
    private var instant = Date(timeIntervalSince1970: 1_700_000_000)
    private let lock = NSLock()

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        instant += seconds
        lock.unlock()
    }
}

/// A binding probe that costs real time to read and, by default, answers
/// differently every time — a window that is expensive to look at and never
/// stops moving.
///
/// It is quiet until a key has been posted, exactly as `KeyReactiveProbe` is, so
/// the §4.3 binding checks ahead of the dispatch pass at no cost and the price is
/// paid only where settling pays it.
///
/// Real sleeping is the point rather than an accident: this double exists for the
/// vector that asserts `waitedMs` against the wall clock, and a fake clock cannot
/// fail an executor that answers that field with a constant.
final class SettleCostProbe: HostElementBindingProbe {
    private let log: KeyEventLog
    private let costPerLook: TimeInterval
    private let stabilises: Bool
    private let lock = NSLock()
    private var looks = 0

    /// How many times settling paid to look at the window.
    var looksTaken: Int {
        lock.lock()
        defer { lock.unlock() }
        return looks
    }

    init(log: KeyEventLog, costPerLook: TimeInterval, stabilises: Bool = false) {
        self.log = log
        self.costPerLook = costPerLook
        self.stabilises = stabilises
    }

    func isReferenceAlive(_ binding: HostElementBinding) -> Bool { true }
    func processStartTime(pid: pid_t) -> UInt64? { hostTestProcessStartTime }

    func currentDigestInput(_ binding: HostElementBinding) -> HostElementDigestInput? {
        guard !log.posted.isEmpty else {
            return binding.digestInput
        }

        Thread.sleep(forTimeInterval: costPerLook)
        lock.lock()
        looks += 1
        let index = looks
        lock.unlock()

        return stabilises
            ? HostElementDigestInput(role: "AXButton", label: "Settled")
            : HostElementDigestInput(role: "AXButton", label: "Frame \(index)")
    }
}

// MARK: - Fixture values

let hostTestPid: pid_t = 4711
let hostTestProcessStartTime: UInt64 = 1_234_567
let hostTestWindowBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
let hostTestWindowTitle = "Untitled"
let hostTestAppId = "com.apple.Notes"

/// A real `AXUIElement`, needed by the `dispatch.key` vectors: `CFEqual` is what
/// the focus check compares with, and it has no fake. Creating an application
/// element neither requires Accessibility nor touches the process — it is an
/// opaque handle, used here only for its identity, so a test keeps the instance
/// it made and hands the *same* one to the binding and to the environment.
func hostTestElement(pid: pid_t = hostTestPid) -> AXUIElement {
    AXUIElementCreateApplication(pid)
}

func hostTestWindow(
    windowId: CGWindowID = 1,
    pid: pid_t = hostTestPid,
    appId: String = hostTestAppId,
    bounds: CGRect = hostTestWindowBounds,
    title: String? = hostTestWindowTitle,
    layer: Int = 0,
    zIndex: Int = 3
) -> HostWindowInfo {
    HostWindowInfo(
        pid: pid,
        windowId: windowId,
        appId: appId,
        appName: "Notes",
        title: title,
        bounds: bounds,
        layer: layer,
        zIndex: zIndex,
        onScreen: true,
        displayId: "1"
    )
}

func hostTestBinding(
    token: String,
    digestInput: HostElementDigestInput,
    enabled: Bool = true,
    frame: HostRect? = nil,
    element: AXUIElement? = nil,
    actions: [HostElementActionName] = [.press],
    dispatchPid: pid_t = hostTestPid,
    dispatchProcessStartTime: UInt64 = hostTestProcessStartTime
) -> HostElementBinding {
    HostElementBinding(
        token: token,
        parentToken: nil,
        depth: 1,
        pid: hostTestPid,
        processStartTime: hostTestProcessStartTime,
        dispatchPid: dispatchPid,
        dispatchProcessStartTime: dispatchProcessStartTime,
        digestInput: digestInput,
        element: element,
        observed: HostObservedElement(
            token: token,
            stableId: nil,
            parentToken: nil,
            depth: 1,
            role: digestInput.role,
            subrole: nil,
            axIdentifier: nil,
            title: digestInput.title,
            label: digestInput.label,
            value: nil,
            placeholder: nil,
            enabled: enabled,
            focused: false,
            selected: nil,
            frame: frame,
            actions: actions,
            digest: hostElementDigest(digestInput),
            truncated: []
        )
    )
}

/// A snapshot of `window`, carrying one element and a window digest computed the
/// way `dispatch.point`'s live check recomputes it, so an unchanged window
/// matches and a changed one does not.
func hostTestSnapshot(
    registry: HostSnapshotRegistry,
    session: String,
    window: HostWindowInfo = hostTestWindow(),
    capturedAt: Int64 = hostNowMs(),
    imagePath: String? = nil,
    image: HostImageReference? = nil,
    enabled: Bool = true,
    elementRole: String = "AXButton",
    elementLabel: String = "Send",
    elementFrame: HostRect? = nil,
    element: AXUIElement? = nil,
    elementActions: [HostElementActionName] = [.press],
    dispatchPid: pid_t? = nil,
    dispatchProcessStartTime: UInt64? = nil
) -> HostSnapshot {
    let id = registry.nextSnapshotId()
    let binding = hostTestBinding(
        token: "el_\(id)_0",
        digestInput: HostElementDigestInput(
            role: elementRole,
            label: elementLabel,
            frameInWindow: elementFrame?.cgRect
        ),
        enabled: enabled,
        frame: elementFrame,
        element: element,
        actions: elementActions,
        dispatchPid: dispatchPid ?? hostTestPid,
        dispatchProcessStartTime:
            dispatchProcessStartTime ?? hostTestProcessStartTime
    )

    let windowDigest = hostWindowDigest(
        elementDigests: [binding.digest],
        bounds: window.bounds,
        title: window.title
    )

    let payload = HostSnapshotPayload(
        snapshotId: id,
        capturedAt: capturedAt,
        target: HostWindowTarget(
            pid: window.pid,
            windowId: window.windowId,
            appId: window.appId,
            appName: window.appName,
            title: window.title,
            bounds: HostRect(window.bounds),
            layer: window.layer,
            zIndex: window.zIndex,
            displayId: window.displayId
        ),
        windowDigest: windowDigest,
        focusedElementToken: nil,
        selectedText: nil,
        image: image,
        displays: [],
        obscuringRects: [],
        elements: [binding.observed],
        truncated: HostSnapshotTruncation(elements: false, depth: false),
        difference: nil,
        menu: nil
    )

    return HostSnapshot(
        id: id,
        session: session,
        pid: window.pid,
        windowId: window.windowId,
        capturedAt: capturedAt,
        windowDigest: windowDigest,
        payload: payload,
        bindings: [binding],
        imagePath: imagePath
    )
}

/// A snapshot minted by the **real** tree walk over a fake tree, so the window
/// digest under test is the one `observe` would have recorded rather than one the
/// fixture computed for itself. Pair it with `FakeRecomputingProbe` to put both
/// ends of §4.3 in the same test.
func hostTestWalkedSnapshot(
    registry: HostSnapshotRegistry,
    session: String,
    root: FakeNode,
    window: HostWindowInfo = hostTestWindow(),
    image: HostImageReference? = hostTestImage()
) -> (snapshot: HostSnapshot, walk: HostTreeWalkResult) {
    let id = registry.nextSnapshotId()
    let capturedAt = hostNowMs()
    let walk = hostWalkTree(
        root: root,
        pid: window.pid,
        processStartTime: hostTestProcessStartTime,
        tokenPrefix: id,
        bounds: HostTreeWalkBounds(maxElements: 100, maxDepth: 32, maxTextChars: 500)
    )

    let windowDigest = hostWindowDigest(
        elementDigests: walk.elements.map(\.digest),
        bounds: window.bounds,
        title: window.title
    )

    let payload = HostSnapshotPayload(
        snapshotId: id,
        capturedAt: capturedAt,
        target: HostWindowTarget(
            pid: window.pid,
            windowId: window.windowId,
            appId: window.appId,
            appName: window.appName,
            title: window.title,
            bounds: HostRect(window.bounds),
            layer: window.layer,
            zIndex: window.zIndex,
            displayId: window.displayId
        ),
        windowDigest: windowDigest,
        focusedElementToken: walk.focusedToken,
        selectedText: nil,
        image: image,
        displays: [],
        obscuringRects: [],
        elements: walk.elements,
        truncated: walk.truncated,
        difference: nil,
        menu: nil
    )

    let snapshot = HostSnapshot(
        id: id,
        session: session,
        pid: window.pid,
        windowId: window.windowId,
        capturedAt: capturedAt,
        windowDigest: windowDigest,
        payload: payload,
        bindings: walk.bindings,
        imagePath: nil
    )

    return (snapshot, walk)
}

func hostTestImage(scale: Double = 2.0) -> HostImageReference {
    HostImageReference(
        path: "/tmp/maka-cu-tests/snap.png",
        format: .png,
        widthPx: Int(hostTestWindowBounds.width * scale),
        heightPx: Int(hostTestWindowBounds.height * scale),
        byteLength: 1,
        sha256: "sha256:" + String(repeating: "0", count: 64),
        scale: scale
    )
}

// MARK: - Server harness

/// Drives `HostProtocolServer.handle(line:)` and collects whole response lines.
/// The lanes are real serial queues, so responses are awaited rather than read.
final class ServerHarness {
    let server: HostProtocolServer
    let environment: FakeEnvironment
    private let inbox: LineInbox
    private let imageDirectory: URL

    private final class LineInbox {
        private let lock = NSLock()
        private var lines: [Data] = []

        func append(_ data: Data) {
            lock.lock()
            lines.append(data)
            lock.unlock()
        }

        func take() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return lines.isEmpty ? nil : lines.removeFirst()
        }
    }

    init(environment: FakeEnvironment = FakeEnvironment()) {
        imageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        let inbox = LineInbox()
        self.inbox = inbox
        self.environment = environment
        server = HostProtocolServer(
            output: HostOutputWriter { inbox.append($0) },
            environment: environment
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: imageDirectory)
    }

    func send(_ line: String) {
        server.handle(line: line)
    }

    func sendHello(protocolVersion: String = makaCuProtocolVersion, imageDir: String? = nil) {
        let directory = imageDir ?? imageDirectory.path
        send("""
        {"jsonrpc":"2.0","id":1,"method":"host.hello","params":{"protocol":"\(protocolVersion)","hostPid":\(ProcessInfo.processInfo.processIdentifier),"imageDir":"\(directory)","allowGlobalPointer":false}}
        """)
    }

    /// Handshake, one session, and a snapshot registered directly — a snapshot
    /// minted through `observe` would need a live Accessibility tree, and the
    /// dispatch rules under test all run before the element is touched.
    @discardableResult
    func begin(session: String = "s1", captureScope: String = "window") throws -> [String: Any] {
        sendHello()
        _ = try awaitResponse()
        send(#"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"\#(session)","captureScope":"\#(captureScope)"}}"#)
        return try awaitResponse()
    }

    func install(_ snapshot: HostSnapshot) {
        server.currentRegistry().register(snapshot)
    }

    func awaitResponse(timeout: TimeInterval = 2) throws -> [String: Any] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let next = inbox.take() {
                return try XCTUnwrap(try JSONSerialization.jsonObject(with: next) as? [String: Any])
            }

            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        throw HostHarnessTimeout()
    }

    /// The `result` object of the next response, which is where every domain
    /// outcome lives — §1.1 keeps JSON-RPC `error` for unusable requests only.
    func awaitResult(timeout: TimeInterval = 2) throws -> [String: Any] {
        let response = try awaitResponse(timeout: timeout)
        XCTAssertNil(response["error"], "a domain outcome is never a JSON-RPC error")
        return try XCTUnwrap(response["result"] as? [String: Any])
    }
}

struct HostHarnessTimeout: Error {}
