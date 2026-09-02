import ApplicationServices
import CoreGraphics
import Foundation

/// §5 — the observation payload. Structured data only: no rendered tree, no
/// catalogue text, nothing the model reads as prose. Maka's runtime owns every
/// model-facing word.

public struct HostObservedElement: Codable, Equatable, Sendable {
    public let token: String
    public let stableId: Int?
    public let parentToken: String?
    public let depth: Int
    public let role: String
    public let subrole: String?
    public let axIdentifier: String?
    /// `AXTitle`. It is a separate field from `label` rather than folded into it
    /// because the two are separate attributes and §4.3 digests them separately:
    /// a wire that merged them could not report `detail.changed: ["title"]`
    /// against anything the host had been shown.
    ///
    /// It was missing from `maka.cu/3` until the menu bar needed it, and it was
    /// already a hole before that. §4.3 lists `title` among the digest inputs and
    /// §6.2 reports it in `detail.changed`, so the protocol could tell a host
    /// *the title changed* about a field it had never sent — the host's only
    /// possible response being to re-observe and compare nothing.
    ///
    /// Measured on a background Calculator: of 35 window elements 23 carry a
    /// `label`, because AppKit's controls set `AXDescription` (`删除`, `清除`,
    /// `百分比`). Of 126 menu elements **2** do. Menu items name themselves with
    /// `AXTitle` and set no description at all, so without this field a menu
    /// observation is 126 anonymous nodes and the feature is worthless.
    public let title: String?
    public let label: String?
    public let value: String?
    public let placeholder: String?
    public let enabled: Bool
    public let focused: Bool
    public let selected: Bool?
    /// Window-local logical points, origin at the window's top-left. §5.
    public let frame: HostRect?
    public let actions: [HostElementActionName]
    public let digest: String
    /// Which of this element's text fields were cut at `maxTextChars`. Empty is
    /// emitted, never omitted, so "was anything cut" is a field read.
    public let truncated: [HostElementTextField]
}

public enum HostElementTextField: String, Codable, Equatable, Sendable {
    case title
    case label
    case value
    case placeholder
}

public struct HostSelectedText: Codable, Equatable, Sendable {
    public let text: String
    public let truncated: Bool
}

public struct HostImageReference: Codable, Equatable, Sendable {
    public let path: String
    public let format: HostImageFormat
    public let widthPx: Int
    public let heightPx: Int
    public let byteLength: Int
    public let sha256: String
    /// §5 — measured as `widthPx / target.bounds.width` from the image actually
    /// captured, never read off `NSScreen.backingScaleFactor`.
    public let scale: Double
}

public struct HostDisplayInfo: Codable, Equatable, Sendable {
    public let displayId: String
    public let logicalBounds: HostRect
    public let sourceBoundsPx: HostRect
    public let scaleFactor: Double
}

public struct HostWindowTarget: Codable, Equatable, Sendable {
    public let pid: Int32
    public let processGeneration: String
    public let windowId: UInt32
    /// §5.1 — the one namespace, spelled the same way `apps.list`, `window.list`
    /// and the `apps.launch` result spell it for the same process. There is no
    /// `bundleId` beside it: a caller that wants to know whether the process has
    /// a bundle id reads whether this starts with `pid:`.
    public let appId: String
    public let appName: String
    public let title: String?
    public let bounds: HostRect
    public let layer: Int
    public let zIndex: Int
    public let displayId: String?
}

public struct HostSnapshotTruncation: Codable, Equatable, Sendable {
    public let elements: Bool
    public let depth: Bool
}

/// §5.8 — the application's menu bar, when the host asked for it.
///
/// A second array rather than a second root inside `elements`, for three reasons
/// that are all about what the *rest* of the executor would otherwise have to
/// remember:
///
/// 1. `windowDigest` is taken over `elements`, and settling recomputes it — one
///    Accessibility round trip per recorded element, per look. Folding 274 menu
///    elements into a Finder window's 1500 would have made every settle sample
///    18% more expensive for elements that cannot change while the window does.
/// 2. `elements` means "what is in this window", and the menu bar is not in it.
///    A consumer that filtered by role would be guessing at a distinction the
///    wire can simply state.
/// 3. Menu elements carry no `frame` (§5.3) and their `enabled` answers a
///    different question (§5.8). Separating them means no consumer has to ask
///    which kind of element it is holding before it reads a field.
///
/// Tokens are minted from the same snapshot and resolve through the same
/// dictionary, so `dispatch.element` addresses a menu item exactly as it
/// addresses a button.
public struct HostMenuObservation: Codable, Equatable, Sendable {
    /// Rooted at `AXMenuBar`. Empty means the application has no menu bar at all;
    /// a single root element with no children means it has one and it is empty.
    public let elements: [HostObservedElement]
    public let truncated: HostSnapshotTruncation

    public init(elements: [HostObservedElement], truncated: HostSnapshotTruncation) {
        self.elements = elements
        self.truncated = truncated
    }
}

public struct HostSnapshotPayload: Codable, Equatable, Sendable {
    public let snapshotId: String
    public let capturedAt: Int64
    public let target: HostWindowTarget
    public let windowDigest: String
    public let focusedElementToken: String?
    public let selectedText: HostSelectedText?
    public let image: HostImageReference?
    public let displays: [HostDisplayInfo]
    public let obscuringRects: [HostRect]
    public let elements: [HostObservedElement]
    public let truncated: HostSnapshotTruncation
    public let difference: HostObservationDifferencePayload?
    /// §5.8 — absent when the host did not ask for the menu bar, so "we did not
    /// look" and "we looked and there is nothing" are different reads. Every
    /// other optional here is `null`-when-absent because absence is a fact about
    /// the window; this one is a fact about the request.
    public let menu: HostMenuObservation?
}

// MARK: - Tree source

/// The tree walk is written against this protocol rather than `AXUIElement`
/// directly so the bounds, truncation flags and digest inputs can be tested
/// without a live desktop. The Accessibility adapter lives in `HostAXNode`.
public protocol HostAccessibilityNode: AnyObject {
    var axElement: AXUIElement? { get }
    /// The process that receives input for this element. For ordinary AppKit
    /// elements this is the application pid; for a WKWebView/Chromium subtree it
    /// may be the out-of-process WebContent/renderer pid.
    var actualPid: pid_t? { get }
    var role: String { get }
    var subrole: String? { get }
    var axIdentifier: String? { get }
    var title: String? { get }
    var label: String? { get }
    /// Untruncated. Truncation for the wire happens in the walker, and the
    /// digest is taken over this value — see §4.3.
    var value: String? { get }
    var placeholder: String? { get }
    var enabled: Bool { get }
    var focused: Bool { get }
    var selected: Bool? { get }
    /// Window-local logical points.
    var frameInWindow: CGRect? { get }
    var rawActionNames: [String] { get }
    /// The live `AXParent` role chain, root-ward — the same read the binding
    /// probe makes at dispatch time. `nil` for a node with no element behind it
    /// (fixtures and tests), which leaves the caller its traversal chain.
    ///
    /// It is a property of the node rather than a call the walker makes on
    /// `HostAX` so that a test can put a node with a live chain in front of the
    /// walk. Without it, every fixture reports no chain, the walk falls back to
    /// its own traversal, and the seam where the two ends disagree is the one
    /// thing the suite cannot reach.
    var liveAncestorRoles: [String]? { get }
    var children: [HostAccessibilityNode] { get }
}

public extension HostAccessibilityNode {
    var actualPid: pid_t? { nil }
}

public struct HostTreeWalkBounds: Equatable, Sendable {
    public let maxElements: Int
    public let maxDepth: Int
    public let maxTextChars: Int
    /// The instant the walk stops descending, or `nil` for a walk with no clock
    /// on it. Absolute rather than a duration because §7.5 may run the walk four
    /// times for one `observe`, and four walks each given the whole budget is
    /// four times the budget.
    public let deadline: Date?

    public init(maxElements: Int, maxDepth: Int, maxTextChars: Int, deadline: Date? = nil) {
        self.maxElements = maxElements
        self.maxDepth = maxDepth
        self.maxTextChars = maxTextChars
        self.deadline = deadline
    }
}

public struct HostTreeWalkResult {
    public let elements: [HostObservedElement]
    public let bindings: [HostElementBinding]
    public let truncated: HostSnapshotTruncation
    public let focusedToken: String?
}

/// Remove a leaf accessibility mirror when the same snapshot contains exactly
/// one renderer-owned WebContent element with the same semantic identity and
/// geometry. The renderer element keeps its original token and parent.
///
/// Non-leaf mirrors are retained because removing one would orphan its children.
/// Ambiguous matches are retained so dispatch can fail closed rather than hide
/// evidence that the tree is ambiguous.
public func hostRemovingShadowedWebMirrors(
    _ result: HostTreeWalkResult
) -> HostTreeWalkResult {
    let parentTokens = Set(result.bindings.compactMap(\.parentToken))
    var replacements: [String: String] = [:]

    for binding in result.bindings
    where binding.dispatchPid == binding.pid && !parentTokens.contains(binding.token) {
        let matches = result.bindings.filter {
            $0.token != binding.token
                && hostIsWebContentEquivalent(recorded: binding, candidate: $0)
        }
        if matches.count == 1, let replacement = matches.first {
            replacements[binding.token] = replacement.token
        }
    }

    guard !replacements.isEmpty else {
        return result
    }

    return HostTreeWalkResult(
        elements: result.elements.filter { replacements[$0.token] == nil },
        bindings: result.bindings.filter { replacements[$0.token] == nil },
        truncated: result.truncated,
        focusedToken: result.focusedToken.flatMap { replacements[$0] ?? $0 }
    )
}

/// Breadth-agnostic depth-first walk. Nodes are numbered in traversal order, and
/// the token embeds the snapshot nonce so it can only ever be looked up in the
/// dictionary it came from — §4.2 forbids parsing an index back out of a token
/// and re-walking the tree, which is exactly the upstream defect being removed.
///
/// `now` is a seam. A walk that runs out of time is otherwise only reachable by
/// putting a window in front of it that takes seconds to read, and the windows
/// that do that are open and save panels — which cannot be opened from a test
/// without driving an application into one.
public func hostWalkTree(
    root: HostAccessibilityNode,
    pid: pid_t,
    processStartTime: UInt64,
    tokenPrefix: String,
    bounds: HostTreeWalkBounds,
    isMenu: Bool = false,
    // Whether a node's subtree is walked at all. It decides descent only: the
    // node itself is already emitted, and — this is the part that matters — the
    // sibling numbering it is asked about is unaffected, because `siblingIndex`
    // comes from `children.enumerated()` over the full child list either way.
    //
    // That distinction is not academic. Filtering a *child list* is what broke
    // menu dispatch: the walk dropped the Apple menu before indexing and the
    // dispatch-time probe did not, so every bar item recorded an index one below
    // what dispatch recomputed and was refused `element_changed` on the first
    // press. A predicate that only says "do not go deeper here" cannot
    // reintroduce that, which is why the menu scope is expressed this way rather
    // than by handing the walk a shorter list of menus.
    expands: (HostAccessibilityNode, Int) -> Bool = { _, _ in true },
    now: () -> Date = Date.init
) -> HostTreeWalkResult {
    var elements: [HostObservedElement] = []
    var bindings: [HostElementBinding] = []
    var focusedToken: String?
    var hitElementBound = false
    var hitDepthBound = false
    var hitTimeBound = false
    var nextIndex = 0
    var processStartTimes: [pid_t: UInt64] = [pid: processStartTime]

    func token(for index: Int) -> String {
        "el_\(tokenPrefix)_\(index)"
    }

    func visit(
        _ node: HostAccessibilityNode,
        parentToken: String?,
        depth: Int,
        ancestorRoles: [String],
        siblingIndex: Int
    ) {
        guard elements.count < bounds.maxElements else {
            hitElementBound = true
            return
        }

        // The clock is a bound like the other two, and it is checked on the same
        // line as the element count because this is the point past which a node
        // costs another round of Accessibility reads. Every read below crosses
        // into the observed process, and against an application that hosts its
        // window in another process — every open and save panel does, in
        // `com.apple.appkit.xpc.openAndSavePanelService` — one node costs tens of
        // milliseconds instead of one. Measured on this machine: an ordinary
        // window is 0.8–7.5 ms per element, that panel is 23.6 ms and rising, so
        // 1500 elements of it took 35 s against a host that gives the whole
        // request 20 s. The host's answer to a request that overruns is to cancel
        // it and tear the executor down, so an unbounded walk does not merely
        // return late, it takes the session with it.
        //
        // The root is exempt. A snapshot with no elements carries no tokens, so
        // the host could not address the window it just observed, and every
        // dispatch against it would be `element_unknown`.
        if !elements.isEmpty, let deadline = bounds.deadline, now() >= deadline {
            hitTimeBound = true
            return
        }

        let selfToken = token(for: nextIndex)
        nextIndex += 1

        let title = hostTruncate(node.title, limit: bounds.maxTextChars)
        let label = hostTruncate(node.label, limit: bounds.maxTextChars)
        let value = hostTruncate(node.value, limit: bounds.maxTextChars)
        let placeholder = hostTruncate(node.placeholder, limit: bounds.maxTextChars)

        var truncatedFields: [HostElementTextField] = []
        if title.wasTruncated {
            truncatedFields.append(.title)
        }
        if label.wasTruncated {
            truncatedFields.append(.label)
        }
        if value.wasTruncated {
            truncatedFields.append(.value)
        }
        if placeholder.wasTruncated {
            truncatedFields.append(.placeholder)
        }

        let actions = hostNormalizedActions(node.rawActionNames)

        // §4.3's field list, assembled where the probe assembles it too. The
        // ancestor chain is read live rather than taken from this walk's own
        // traversal: the walker elides wrapper nodes and `AXParent` does not, so
        // on any Chromium tree the two disagree and every dispatch is refused
        // `element_changed` with `changed: ["ancestors"]` on an element nothing
        // touched — measured against Maka's own window, where it refused the
        // first click of every run. The traversal chain remains the fallback for
        // a node with no element behind it, which is fixtures only.
        let digestInput = hostElementDigestInput(
            node: node,
            depth: depth,
            actions: actions,
            ancestorRoles: node.liveAncestorRoles ?? ancestorRoles,
            siblingIndex: siblingIndex
        )

        let observed = HostObservedElement(
            token: selfToken,
            stableId: nil,
            parentToken: parentToken,
            depth: depth,
            role: node.role,
            subrole: node.subrole,
            axIdentifier: node.axIdentifier,
            title: title.text,
            label: label.text,
            value: value.text,
            placeholder: placeholder.text,
            enabled: node.enabled,
            focused: node.focused,
            selected: node.selected,
            frame: node.frameInWindow.map(HostRect.init),
            actions: actions,
            digest: hostElementDigest(digestInput),
            truncated: truncatedFields
        )

        let reportedActualPid = node.actualPid ?? pid
        let dispatchStartTime: UInt64?
        if let cached = processStartTimes[reportedActualPid] {
            dispatchStartTime = cached
        } else {
            let measured = hostProcessStartTime(pid: reportedActualPid)
            if let measured {
                processStartTimes[reportedActualPid] = measured
            }
            dispatchStartTime = measured
        }
        let dispatchPid = dispatchStartTime == nil ? pid : reportedActualPid

        elements.append(observed)
        bindings.append(
            HostElementBinding(
                token: selfToken,
                parentToken: parentToken,
                depth: depth,
                pid: pid,
                processStartTime: processStartTime,
                dispatchPid: dispatchPid,
                dispatchProcessStartTime: dispatchStartTime ?? processStartTime,
                digestInput: digestInput,
                element: node.axElement,
                observed: observed,
                isMenu: isMenu
            )
        )

        if node.focused, focusedToken == nil {
            focusedToken = selfToken
        }

        let children = node.children
        // `maxDepth` is a count of levels, so the deepest element a walk may emit
        // sits at `maxDepth - 1`. Returning at `depth == maxDepth` emitted one
        // level more than the bound names — 65 levels for a budget of 64 — and
        // the host has no way to see that from the wire.
        if !children.isEmpty, depth + 1 >= bounds.maxDepth {
            hitDepthBound = true
            return
        }

        // Not a truncation: the caller asked for this shape, so neither
        // `truncated` flag is raised. Saying "the tree was cut short" about a
        // scope the host chose would put the host's own request in front of the
        // model as a limitation of the machine.
        guard expands(node, depth) else {
            return
        }

        // Ancestor roles are capped at 8 levels root-ward (§4.3). Keeping the
        // *nearest* eight is what makes the cap useful: a deep Electron tree
        // changes at the root far more often than next to the element.
        let childAncestors = Array(([node.role] + ancestorRoles).prefix(8))
        for (offset, child) in children.enumerated() {
            visit(
                child,
                parentToken: selfToken,
                depth: depth + 1,
                ancestorRoles: childAncestors,
                siblingIndex: offset
            )
        }
    }

    visit(root, parentToken: nil, depth: 0, ancestorRoles: [], siblingIndex: 0)

    return HostTreeWalkResult(
        elements: elements,
        bindings: bindings,
        // §5.2 — a walk stopped by the clock reports `elements`, because what it
        // returned is short of what the window holds and that is the one fact
        // the host has a field for. It does not raise `depth`: that names a
        // level the walk refused to go below, and after a time cut no level was
        // the reason. What neither field can say is *why*, which is a gap in the
        // wire and is written down as one in §5.2 — but silence is not the
        // alternative. An executor that returned a short tree with
        // `truncated: { elements: false, depth: false }` would be telling the
        // host it had seen the whole window.
        truncated: HostSnapshotTruncation(
            elements: hitElementBound || hitTimeBound,
            depth: hitDepthBound
        ),
        focusedToken: focusedToken
    )
}

public struct HostTruncatedText: Equatable, Sendable {
    public let text: String?
    public let wasTruncated: Bool
}

public func hostTruncate(_ value: String?, limit: Int) -> HostTruncatedText {
    guard let value else {
        return HostTruncatedText(text: nil, wasTruncated: false)
    }

    guard value.count > limit else {
        return HostTruncatedText(text: value, wasTruncated: false)
    }

    return HostTruncatedText(text: String(value.prefix(limit)), wasTruncated: true)
}
