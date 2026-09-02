import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private typealias HostAXGetActualPid = @convention(c) (
    AXUIElement,
    UnsafeMutablePointer<pid_t>
) -> AXError

private let hostAXGetActualPid: HostAXGetActualPid? = {
    guard let handle = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        RTLD_LAZY | RTLD_LOCAL
    ) else {
        return nil
    }
    guard let symbol = dlsym(handle, "_AXUIElementGetActualPid") else {
        return nil
    }
    return unsafeBitCast(symbol, to: HostAXGetActualPid.self)
}()

public func hostActualPidSPIAvailable() -> Bool {
    hostAXGetActualPid != nil
}

/// Everything in this file talks to macOS. It is kept apart from the protocol
/// logic so the lifecycle, binding and path rules stay testable without a
/// desktop, and so this is the only place to look when Accessibility behaviour
/// changes underneath us.

// MARK: - Process identity (E2)

/// §4.3 E2 — a recycled pid must fail. `p_starttime` is the only field that
/// distinguishes "same process" from "same number".
public func hostProcessStartTime(pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard read == size else {
        return nil
    }

    return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
}

// MARK: - Window inventory

public struct HostWindowInfo: Equatable, Sendable {
    public let pid: pid_t
    public let windowId: CGWindowID
    /// §5.1 — the one namespace. `appName` beside it is a display string and is
    /// never matched against; its absence here is what made an app string
    /// unresolvable against this list.
    public let appId: String
    public let appName: String
    public let title: String?
    public let bounds: CGRect
    public let layer: Int
    public let zIndex: Int
    public let onScreen: Bool
    public let displayId: String?
}

func hostFirstWindowCandidate<Element>(
    _ candidates: [(element: Element, frame: CGRect?)],
    matching bounds: CGRect
) -> Element? {
    candidates.first { candidate in
        guard let frame = candidate.frame else {
            return false
        }
        return abs(frame.origin.x - bounds.origin.x) < 1
            && abs(frame.origin.y - bounds.origin.y) < 1
            && abs(frame.width - bounds.width) < 1
            && abs(frame.height - bounds.height) < 1
    }?.element
}

public enum HostWindowInventory {
    /// Front-to-back. `zIndex` counts down from the window count so it is
    /// strictly decreasing and never ties — the host resolves occlusion with it.
    public static func onScreenWindows() -> [HostWindowInfo] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let total = infoList.count
        return infoList.enumerated().compactMap { offset, info in
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let number = info[kCGWindowNumber as String] as? NSNumber,
                let layer = info[kCGWindowLayer as String] as? Int,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                return nil
            }

            let title = info[kCGWindowName as String] as? String
            return HostWindowInfo(
                pid: pid,
                windowId: CGWindowID(number.uint32Value),
                appId: hostAppId(
                    bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                    pid: pid
                ),
                appName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: (title?.isEmpty ?? true) ? nil : title,
                bounds: bounds,
                layer: layer,
                zIndex: total - offset,
                onScreen: true,
                displayId: displayId(containing: bounds)
            )
        }
    }

    /// §5 — the layer-0 windows stacked above the target, in screen points.
    ///
    /// The titleless full-screen Dock surface is excluded here rather than in the
    /// host: it covers every display at layer 0 and would mark every window as
    /// obscured. The host filters it by hand today, and the filter belongs on the
    /// side that reads the window list.
    public static func obscuringRects(above target: HostWindowInfo, in windows: [HostWindowInfo]) -> [CGRect] {
        windows
            .filter { $0.layer == 0 && $0.zIndex > target.zIndex && $0.windowId != target.windowId }
            .filter { !isFullScreenDockSurface($0) }
            .filter { $0.bounds.intersects(target.bounds) }
            .map(\.bounds)
    }

    static func isFullScreenDockSurface(_ window: HostWindowInfo) -> Bool {
        guard window.appName == "Dock", window.title == nil else {
            return false
        }

        return NSScreen.screens.contains { screen in
            window.bounds.width >= screen.frame.width && window.bounds.height >= screen.frame.height
        }
    }

    static func displayId(containing bounds: CGRect) -> String? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }

            if CGDisplayBounds(CGDirectDisplayID(number.uint32Value)).contains(center) {
                return String(number.uint32Value)
            }
        }

        return nil
    }

    public static func displays() -> [HostDisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayId = CGDirectDisplayID(number.uint32Value)
            let logical = CGDisplayBounds(displayId)
            let scale = Double(screen.backingScaleFactor)
            return HostDisplayInfo(
                displayId: String(number.uint32Value),
                logicalBounds: HostRect(logical),
                sourceBoundsPx: HostRect(
                    x: 0,
                    y: 0,
                    width: Double(CGDisplayPixelsWide(displayId)) * scale,
                    height: Double(CGDisplayPixelsHigh(displayId)) * scale
                ),
                scaleFactor: scale
            )
        }
    }
}

/// The displays attached right now, asked of the window server rather than read
/// off `NSScreen.screens`. §5.5 — AppKit's caches are refreshed by the main run
/// loop, and this executor's main thread sits in `readLine`; a lane that asks
/// `NSScreen` whether a display exists can be answered from a snapshot taken
/// before the display was plugged in. `screen.capture` validates the caller's
/// `displayId` against this, so the answer has to come from the machine.
public func hostActiveDisplayIds() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
        return []
    }

    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
        return []
    }

    return Array(ids.prefix(Int(count)))
}

/// `CGSessionCopyCurrentDictionary` is the only reliable lock signal available to
/// a background process: Accessibility and ScreenCaptureKit both fail on a locked
/// screen, but they fail with codes that also mean other things.
public func hostScreenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return false
    }

    return session["CGSSessionScreenIsLocked"] as? Bool == true
}

// MARK: - Accessibility node adapter

/// A key that lets an `AXUIElement` be a dictionary key. `CFEqual` and `CFHash`
/// are the identity Accessibility itself uses, and they are what the walk
/// already compares children with.
struct HostAXElementKey: Hashable {
    private let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: HostAXElementKey, rhs: HostAXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// The §4.3 ancestor chains produced during one walk, kept so the walk pays for
/// each one once.
///
/// `HostAX.ancestorRoles` climbs `AXParent` a level at a time and reads a role at
/// each level: up to sixteen round trips, for every element, re-deriving a chain
/// its own parent had already derived one call earlier. Against Finder that was
/// half of the walk's Accessibility traffic.
///
/// The memo is keyed by element rather than by position in the traversal, which
/// is what keeps it honest: an ancestor chain is a property of the element, and a
/// child whose `AXParent` is not the node the walk descended from simply misses
/// and climbs for itself. Nothing is assumed about the two agreeing.
final class HostAXAncestryMemo {
    private var chainsIncludingSelf: [HostAXElementKey: [String]] = [:]

    /// The chain the walk would have read live for `element`, given its parent.
    func ancestorRoles(of element: AXUIElement, parent: AXUIElement?) -> [String] {
        guard let parent else {
            return []
        }

        if let cached = chainsIncludingSelf[HostAXElementKey(parent)] {
            return cached
        }

        // A miss still climbs, but what it climbed is by definition the parent's
        // own chain-including-self, so the parent is filled in on the way past
        // and this element's siblings hit.
        let live = HostAX.ancestorRoles(of: element)
        chainsIncludingSelf[HostAXElementKey(parent)] = live
        return live
    }

    /// Records what this element's own children will need: its role in front of
    /// its chain, capped and stopped exactly where `HostAX.ancestorRoles` caps and
    /// stops.
    func record(element: AXUIElement, role: String, ancestorRoles: [String]) {
        let chain: [String]
        if role == kAXWindowRole as String {
            chain = [role]
        } else {
            chain = Array(([role] + ancestorRoles).prefix(8))
        }
        chainsIncludingSelf[HostAXElementKey(element)] = chain
    }
}

/// Wraps one `AXUIElement` as a `HostAccessibilityNode`. The wrapper holds the
/// element, which is what keeps the reference alive for the snapshot's lifetime.
///
/// Every attribute is read once, in one call, on first use. Before that the walk
/// asked the node for `AXRole` four separate times — once for the wire, once for
/// the digest, once to build its children's ancestor chain and once inside
/// `children` — and each of those was an IPC into the observed process. Measured
/// on this machine before the change: 28.5 to 37.7 Accessibility round trips per
/// element, against twelve distinct attributes the wire actually carries.
final class HostAXNode: HostAccessibilityNode {
    let element: AXUIElement
    /// The window this node's frame is expressed relative to, or `nil` for a node
    /// that has no position in any window — which is every node of the menu bar
    /// (§5.8). It is an *absent* frame rather than a converted one because both
    /// of the frames Accessibility offers here would be lies in this field's
    /// declared space (§5.3): an unopened menu item reports the degenerate
    /// `(0, 982, 0, 0)` — measured identical for all 346 of TextEdit's, all 452
    /// of VS Code's — and a menu bar item reports a real *screen* rectangle that
    /// would land outside the window once the origin was subtracted, and would
    /// change the element's digest every time the window moved.
    private let windowBounds: CGRect?
    private let focusedElement: AXUIElement?
    /// §5.8 — set only on the menu bar root. The Apple menu is the system's, not
    /// the application's: it is byte-identical across every application, it is
    /// where `关机` and `重新启动` live, and it costs 59 of TextEdit's 346 menu
    /// elements. The old renderer already dropped it
    /// (`AccessibilitySnapshot.swift`, `shouldSkipChild`); this keeps that rule
    /// and writes it into the protocol (§5.8) so it is a stated scope rather than
    /// a silent omission.
    private let dropsAppleMenu: Bool
    private let ancestry: HostAXAncestryMemo
    private var cached: Attributes?

    init(
        element: AXUIElement,
        windowBounds: CGRect?,
        focusedElement: AXUIElement?,
        dropsAppleMenu: Bool = false,
        ancestry: HostAXAncestryMemo = HostAXAncestryMemo()
    ) {
        self.element = element
        self.windowBounds = windowBounds
        self.focusedElement = focusedElement
        self.dropsAppleMenu = dropsAppleMenu
        self.ancestry = ancestry
    }

    /// One element's answers, taken at one instant.
    ///
    /// That they are taken together is not only cheaper, it is more truthful than
    /// what it replaces: thirty separate reads spread over a millisecond could
    /// report a role from before a change and a value from after it, and the
    /// digest §4.3 takes over them would describe an element that never existed.
    struct Attributes {
        var role: String
        var subrole: String?
        var axIdentifier: String?
        var title: String?
        var label: String?
        var value: String?
        var placeholder: String?
        var enabled: Bool
        var focusedFlag: Bool
        var selected: Bool?
        var frame: CGRect?
        var parent: AXUIElement?
        /// Keyed by the attribute that produced them, because
        /// `childTraversalAttributes` names attributes and a lookup by name is
        /// the only mapping that cannot quietly file one attribute's answer
        /// under another's.
        var childArrays: [String: [AXUIElement]]
    }

    /// The order is the contract between the request and the reply: the reply is
    /// positional, so a name added here has to be read out at the same index.
    static let batchedAttributeNames: [String] = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXIdentifierAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
        "AXPlaceholderValue",
        kAXEnabledAttribute as String,
        kAXFocusedAttribute as String,
        kAXSelectedAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXParentAttribute as String,
    ] + hostChildTraversalAttributeNames

    private static let childArrayStart = batchedAttributeNames.count - hostChildTraversalAttributeNames.count

    private var attributes: Attributes {
        if let cached {
            return cached
        }

        let names = Self.batchedAttributeNames
        // An element whose application refuses the batched call is read the old
        // way rather than reported blank. A blank element is indistinguishable on
        // the wire from an element that genuinely has nothing, and the model
        // cannot act on either — so the slow path stays, and it is the fallback
        // rather than the default.
        let values = HostAX.attributes(element, names) ?? names.map { HostAX.attribute(element, $0) }

        func string(_ index: Int) -> String? {
            guard let text = values[index] as? String, !text.isEmpty else {
                return nil
            }
            return text
        }

        func bool(_ index: Int) -> Bool? {
            guard let value = values[index] else {
                return nil
            }
            return (value as? NSNumber)?.boolValue
        }

        var childArrays: [String: [AXUIElement]] = [:]
        for (offset, name) in hostChildTraversalAttributeNames.enumerated() {
            childArrays[name] = values[Self.childArrayStart + offset] as? [AXUIElement] ?? []
        }

        let attributes = Attributes(
            role: string(0) ?? "AXUnknown",
            subrole: string(1),
            axIdentifier: string(2),
            title: string(3),
            label: string(4),
            value: values[5].flatMap(HostAX.stringLikeValue),
            placeholder: string(6),
            enabled: bool(7) ?? true,
            focusedFlag: bool(8) ?? false,
            selected: bool(9),
            frame: HostAX.rect(position: values[10], size: values[11]),
            parent: values[12].map { $0 as! AXUIElement },
            childArrays: childArrays
        )
        cached = attributes
        return attributes
    }

    var axElement: AXUIElement? { element }

    var role: String {
        attributes.role
    }

    var subrole: String? {
        attributes.subrole
    }

    var axIdentifier: String? {
        attributes.axIdentifier
    }

    var title: String? {
        attributes.title
    }

    var label: String? {
        attributes.label
    }

    var value: String? {
        attributes.value
    }

    var placeholder: String? {
        attributes.placeholder
    }

    var enabled: Bool {
        attributes.enabled
    }

    var focused: Bool {
        guard let focusedElement else {
            return attributes.focusedFlag
        }

        return CFEqual(focusedElement, element)
    }

    var selected: Bool? {
        attributes.selected
    }

    var frameInWindow: CGRect? {
        guard let windowBounds, let frame = attributes.frame else {
            return nil
        }

        return windowRelativeFrame(elementFrame: frame, windowBounds: windowBounds)
    }

    var rawActionNames: [String] {
        HostAX.actionNames(element)
    }

    var actualPid: pid_t? {
        HostAX.actualPid(of: element)
    }

    var liveAncestorRoles: [String]? {
        let roles = ancestry.ancestorRoles(of: element, parent: attributes.parent)
        ancestry.record(element: element, role: attributes.role, ancestorRoles: roles)
        return roles
    }

    var children: [HostAccessibilityNode] {
        let attributes = attributes
        let names = childTraversalAttributes(
            role: attributes.role,
            hasRows: !(attributes.childArrays[kAXRowsAttribute as String]?.isEmpty ?? true),
            hasVisibleChildren: !(attributes.childArrays[axVisibleChildrenAttribute]?.isEmpty ?? true)
        )

        var result: [AXUIElement] = []
        for name in names {
            // A name the batch did not carry is read now rather than skipped.
            // Skipping is what dropped `AXContents` the first time, and a
            // dropped attribute costs a subtree without costing an error.
            let values = attributes.childArrays[name] ?? HostAX.array(element, name)

            for child in values where !result.contains(where: { CFEqual($0, child) }) {
                result.append(child)
            }
        }

        return result
            .filter { !dropsAppleMenu || !HostAX.isAppleMenu($0) }
            .map {
                HostAXNode(
                    element: $0,
                    windowBounds: windowBounds,
                    focusedElement: focusedElement,
                    ancestry: ancestry
                )
            }
    }
}

/// A count of Accessibility round trips, which is the unit the tree walk's cost
/// is actually denominated in — every read below crosses into the observed
/// process, and on this machine one crossing measures 38 µs against an ordinary
/// window and ten times that against a window hosted in another process.
///
/// It is here rather than in a test because the number a benchmark needs is how
/// many crossings *the walk* made, and only the walk can count them. Wall clock
/// alone cannot tell a walk that got slower from a machine that got busier;
/// this can.
///
/// Deliberately not atomic. The executor reads Accessibility on one lane, the
/// increment is a few nanoseconds against a 38 µs round trip, and a lock here
/// would be a measurement that changed what it measured.
enum HostAXTelemetry {
    nonisolated(unsafe) static var roundTrips = 0

    static func reset() {
        roundTrips = 0
    }
}

enum HostAX {
    struct PreparedValueWrite {
        let value: CFTypeRef
        let requestedReadback: String
        let comparesNumerically: Bool
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        HostAXTelemetry.roundTrips += 1
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// Every attribute the walk wants from one element, asked for once.
    ///
    /// `AXUIElementCopyAttributeValue` is one IPC per attribute, and the walk
    /// reads twelve of them off every node — plus the same `AXRole` four separate
    /// times, because four different callers each asked the node for it. Measured
    /// on a background Calculator, 200 iterations: twelve attributes read one at a
    /// time cost 453 µs, and the same twelve through this call cost 229 µs.
    ///
    /// Missing attributes come back as an `AXValue` of type `kAXValueAXErrorType`
    /// rather than being absent, so the returned array is always parallel to
    /// `names` and a caller reads position, never a count. Those placeholders are
    /// mapped to `nil` here so the rest of the adapter sees exactly what a failed
    /// single read would have given it.
    static func attributes(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?]? {
        HostAXTelemetry.roundTrips += 1
        var raw: CFArray?
        guard
            AXUIElementCopyMultipleAttributeValues(
                element,
                names as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0),
                &raw
            ) == .success,
            let values = raw as? [CFTypeRef],
            values.count == names.count
        else {
            return nil
        }

        return values.map { value in
            guard CFGetTypeID(value) == AXValueGetTypeID() else {
                return value
            }
            // An `AXValue` is a real value for position and size, and a wrapped
            // error for everything the element does not answer. Only the second
            // is absence.
            return AXValueGetType(value as! AXValue) == .axError ? nil : value
        }
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Values come back as strings, numbers or booleans depending on the role.
    /// The digest is over the string form, so the conversion has to be stable.
    static func stringLikeValue(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else {
            return nil
        }

        return stringLikeValue(value)
    }

    /// The same conversion applied to a value already in hand, so the batched
    /// read and the single read cannot disagree about what an `AXValue` means.
    static func stringLikeValue(_ value: CFTypeRef) -> String? {
        if let text = value as? String {
            return text.isEmpty ? nil : text
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return (value as? NSNumber)?.boolValue == true ? "true" : "false"
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    /// Preserve the target attribute's scalar type. AppKit sliders reject a
    /// `CFString` even when it contains a valid number; text fields require that
    /// same string and booleans require a real `CFBoolean`.
    static func preparedValueWrite(_ requested: String, for element: AXUIElement) -> PreparedValueWrite? {
        guard let current = attribute(element, kAXValueAttribute) else {
            return PreparedValueWrite(
                value: requested as CFString,
                requestedReadback: requested,
                comparesNumerically: false
            )
        }

        if CFGetTypeID(current) == CFBooleanGetTypeID() {
            switch requested.lowercased() {
            case "true", "1":
                return PreparedValueWrite(
                    value: kCFBooleanTrue,
                    requestedReadback: "true",
                    comparesNumerically: false
                )
            case "false", "0":
                return PreparedValueWrite(
                    value: kCFBooleanFalse,
                    requestedReadback: "false",
                    comparesNumerically: false
                )
            default:
                return nil
            }
        }

        if current is NSNumber {
            guard let number = Double(requested), number.isFinite else {
                return nil
            }
            return PreparedValueWrite(
                value: NSNumber(value: number),
                requestedReadback: requested,
                comparesNumerically: true
            )
        }

        return PreparedValueWrite(
            value: requested as CFString,
            requestedReadback: requested,
            comparesNumerically: false
        )
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name) else {
            return nil
        }

        return (value as? NSNumber)?.boolValue
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        rect(position: attribute(element, kAXPositionAttribute), size: attribute(element, kAXSizeAttribute))
    }

    /// The pair unboxed, so the batched read and the single read produce the
    /// same rectangle from the same two `AXValue`s.
    static func rect(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size else {
            return nil
        }

        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard
            AXValueGetValue(position as! AXValue, .cgPoint, &origin),
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else {
            return nil
        }

        return CGRect(origin: origin, size: extent)
    }

    static func actionNames(_ element: AXUIElement) -> [String] {
        HostAXTelemetry.roundTrips += 1
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success else {
            return []
        }
        return actions as? [String] ?? []
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        let role = string(element, kAXRoleAttribute)
        let rows = array(element, kAXRowsAttribute)
        let visible = array(element, "AXVisibleChildren")
        let attributes = childTraversalAttributes(
            role: role,
            hasRows: !rows.isEmpty,
            hasVisibleChildren: !visible.isEmpty
        )

        var result: [AXUIElement] = []
        for attribute in attributes {
            let values: [AXUIElement]
            switch attribute {
            case kAXRowsAttribute:
                values = rows
            case "AXVisibleChildren":
                values = visible
            default:
                values = array(element, attribute)
            }

            for child in values where !result.contains(where: { CFEqual($0, child) }) {
                result.append(child)
            }
        }

        return result
    }

    static func array(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name) else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    /// §4.3 E1 — alive means an attribute read answers with something other than
    /// `kAXErrorInvalidUIElement`. A failure for any other reason (a busy app, an
    /// unsupported attribute) is not evidence that the element is gone.
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return result != .invalidUIElement
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return pid
    }

    /// The process that implements this accessibility object. Public
    /// `AXUIElementGetPid` reports the host application for every node in a
    /// WKWebView tree; this SPI reports the WebContent/renderer pid for the
    /// renderer-owned descendants.
    static func actualPid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard let hostAXGetActualPid,
              hostAXGetActualPid(element, &pid) == .success,
              pid > 0
        else {
            return self.pid(of: element)
        }
        return pid
    }

    static func pageScrollButton(
        in element: AXUIElement,
        direction: HostScrollDirection
    ) -> AXUIElement? {
        let wantedSubrole: String
        switch direction {
        case .down, .right:
            wantedSubrole = "AXIncrementPage"
        case .up, .left:
            wantedSubrole = "AXDecrementPage"
        }

        var queue = children(of: element)
        var visited = Set<HostAXElementKey>()
        var examined = 0
        while !queue.isEmpty, examined < 128 {
            let candidate = queue.removeFirst()
            let key = HostAXElementKey(candidate)
            guard visited.insert(key).inserted else {
                continue
            }
            examined += 1

            if string(candidate, kAXSubroleAttribute) == wantedSubrole,
               actionNames(candidate).contains(kAXPressAction as String) {
                return candidate
            }
            queue.append(contentsOf: children(of: candidate))
        }
        return nil
    }

    static func window(pid: pid_t, windowId: CGWindowID, bounds: CGRect) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)

        // Ask first; only reach for the switches if the app really is holding
        // its tree back.
        //
        // `AXEnhancedUserInterface` is the flag VoiceOver sets. Setting it puts
        // an app into a different accessibility mode, it is process-wide, and
        // there is no way to put it back — AppKit apps have shipped bugs under
        // it for years, from slow window resizing to windows that stop
        // reporting at all. This used to be set on *every* app on *every*
        // observation, including the great majority that expose their tree
        // without being asked, which means a read quietly and permanently
        // changed the thing it was reading.
        //
        // Chromium and Electron genuinely need it: they withhold the tree until
        // something asks. So the rule is ask-then-set, not set-then-ask, and an
        // app that already answers is left exactly as it was found.
        var windows = array(application, kAXWindowsAttribute)
        if windows.isEmpty {
            _ = AXUIElementSetAttributeValue(
                application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(
                application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            windows = array(application, kAXWindowsAttribute)
        }

        // There is no public AX attribute carrying a CGWindowID, so the window is
        // matched by its frame against the one the window list reported. Bounds
        // are compared at whole-point resolution because AX and CGWindowList
        // disagree in the sub-pixel digits on scaled displays.
        if let matched = hostFirstWindowCandidate(
            windows.map { ($0, frame($0)) },
            matching: bounds
        ) {
            return matched
        }

        // A sheet is a window to CGWindowList and a child to accessibility. It
        // is never in `AXWindows` — it is a child of its parent window whose
        // role is `AXSheet`, and a drawer is the same shape. Alerts, save
        // panels, print panels and permission prompts are all sheets, so an
        // observer that reads only `AXWindows` goes blind exactly when the app
        // has stopped to ask a question — and `target.resolve` chooses the
        // frontmost window, which while a sheet is up is the sheet.
        //
        // There is no `AXSheets` attribute, which is the trap. AppleScript
        // offers `sheets of window` and that reads like one, but System Events
        // synthesises it by filtering `AXChildren` on role; asking accessibility
        // for "AXSheets" returns an empty list, silently, on a window that
        // plainly has a sheet. Measured against the CUA Lab fixture with its
        // modal open: CGWindowList reported two windows, `AXWindows` reported
        // one, "AXSheets" reported zero, and `AXChildren` had the `AXSheet`
        // sitting in it at exactly the frame the window list had named.
        let sheets = windows.flatMap { window in
            array(window, kAXChildrenAttribute).filter {
                sheetLikeRoles.contains(string($0, kAXRoleAttribute) ?? "")
            }
        }
        return hostFirstWindowCandidate(
            sheets.map { ($0, frame($0)) },
            matching: bounds
        )
    }

    /// Roles that CGWindowList reports as a window of their own while
    /// accessibility reports them as a child of one.
    static let sheetLikeRoles: Set<String> = ["AXSheet", "AXDrawer"]

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        guard let value = attribute(application, kAXFocusedUIElementAttribute) else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// §5.8 — the application's menu bar. It hangs off the *application* element,
    /// not off any window, which is why no amount of walking a window tree ever
    /// reached it: `observe` roots its walk at the window, so `kAXMenuBarAttribute`
    /// was never on any path it took, and menu roles were 0 in every observation
    /// the executor has ever produced.
    ///
    /// This is a read. It does not activate the application, does not open a menu
    /// and does not change the z-order — measured across seven applications in
    /// the background, with the frontmost pid asserted unchanged.
    static func menuBar(pid: pid_t) -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// The Apple menu, which is the first child of every `AXMenuBar`. AppKit
    /// titles it `"Apple"` and does not localise that title: measured on a fully
    /// Chinese-localised system, where every other menu bar item came back
    /// translated (`文件`, `编辑`, `显示`) and this one did not, in all seven
    /// applications probed.
    ///
    /// Matching the title rather than the index is deliberate. If AppKit ever
    /// changed it, matching the title over-includes — the model sees a menu it
    /// has no business in — while matching index 0 would silently drop the
    /// application's own first menu. Of the two failures only the first is
    /// visible on the wire.
    static func isAppleMenu(_ element: AXUIElement) -> Bool {
        string(element, kAXTitleAttribute) == "Apple"
    }

    static func selectedText(_ element: AXUIElement) -> String? {
        string(element, kAXSelectedTextAttribute)
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
        return result == .success && settable.boolValue
    }

    // MARK: Window geometry (§6.1)
    //
    // `frame` above reads both halves at once for the tree walk. Window
    // management needs them apart: `move_window` writes only the origin and
    // `resize_window` only the extent, and an executor that read the pair and
    // wrote the pair back would move a window every time it was asked to resize
    // one.
    //
    // `AXPosition` is in the same space `CGWindowListCopyWindowInfo` reports
    // (§5.3) — measured across seventeen applications on a machine whose second
    // display sits at `(-193, -1080)`, the two agreed to the point on every one,
    // including the four windows with a negative origin. `HostAX.window` has in
    // fact been relying on that agreement all along: it matches AX windows
    // against the window list's frame because there is no public AX attribute
    // carrying a `CGWindowID`.

    static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name) else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name) else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    static func write(_ element: AXUIElement, _ name: String, point: CGPoint) -> AXError {
        var value = point
        guard let boxed = AXValueCreate(.cgPoint, &value) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(element, name as CFString, boxed)
    }

    static func write(_ element: AXUIElement, _ name: String, size: CGSize) -> AXError {
        var value = size
        guard let boxed = AXValueCreate(.cgSize, &value) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(element, name as CFString, boxed)
    }

    static func write(_ element: AXUIElement, _ name: String, flag: Bool) -> AXError {
        AXUIElementSetAttributeValue(element, name as CFString, flag ? kCFBooleanTrue : kCFBooleanFalse)
    }

    static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(element, kAXParentAttribute) else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Recomputes the §4.3 ancestor roles from live parent links. The walk stops
    /// once it has appended the window role, because the tree walk that recorded
    /// the digest was rooted at the window and would never have seen the
    /// application element above it.
    static func ancestorRoles(of element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current = element

        while roles.count < 8, let parent = parent(of: current) {
            let role = string(parent, kAXRoleAttribute) ?? "AXUnknown"
            roles.append(role)
            if role == kAXWindowRole as String {
                break
            }
            current = parent
        }

        return roles
    }

    /// The children a walk actually descends into.
    ///
    /// The Apple menu is dropped here, and dropping it renumbers every sibling
    /// after it. That is the whole reason this exists as one function: the walk
    /// filtered, `siblingIndex` did not, and so every top-level menu recorded a
    /// sibling index one lower than the probe recomputed at dispatch. Every menu
    /// dispatch was refused `element_changed` with `changed: ["siblingIndex"]` —
    /// against an element nothing had touched, in the same second it was
    /// observed. The menu bar was addressable in the observation and unusable in
    /// practice, which is worse than not shipping it.
    ///
    /// It is the third time the two sides of §4.3 have been assembled
    /// separately and drifted (after `ancestorRoles` from two traversals, and
    /// again for the root). One producer, both callers.
    static func traversedChildren(of element: AXUIElement, dropsAppleMenu: Bool) -> [AXUIElement] {
        children(of: element).filter { !dropsAppleMenu || !isAppleMenu($0) }
    }

    /// The element's position among its parent's traversed children, computed
    /// through the same traversal used at observe time so the two cannot
    /// disagree — which now means the same function, not the same intent.
    ///
    /// Whether the Apple menu is dropped is decided here by reading the parent,
    /// not by passing a flag down from the caller. The walk drops it only at the
    /// menu bar itself — `dropsAppleMenu` is set on the root node and not
    /// propagated to its children — so "the parent is an `AXMenuBar`" is the same
    /// rule stated as something both sides can observe. Passing `isMenu` from the
    /// binding instead would over-drop at every depth below the first, and be
    /// indistinguishable from correct until an application shipped a submenu item
    /// titled `Apple`.
    static func siblingIndex(of element: AXUIElement) -> Int {
        guard let parent = parent(of: element) else {
            return 0
        }

        let dropsAppleMenu = string(parent, kAXRoleAttribute) == kAXMenuBarRole as String
        return traversedChildren(of: parent, dropsAppleMenu: dropsAppleMenu)
            .firstIndex(where: { CFEqual($0, element) }) ?? 0
    }
}

/// The binding probe backed by live Accessibility. It builds its digest inputs
/// through `hostElementDigestInput`, the same call `hostWalkTree` records them
/// with, because a probe that assembles the §4.3 field list itself is a second
/// copy of that list — and the two copies have drifted twice now, each time
/// refusing dispatches against elements nothing had touched.
final class HostAXBindingProbe: HostElementBindingProbe {
    let windowBounds: CGRect
    private let limits = HostLimits()

    init(windowBounds: CGRect) {
        self.windowBounds = windowBounds
    }

    func isReferenceAlive(_ binding: HostElementBinding) -> Bool {
        guard let element = binding.element else {
            return false
        }
        return HostAX.isAlive(element)
    }

    func processStartTime(pid: pid_t) -> UInt64? {
        hostProcessStartTime(pid: pid)
    }

    func actualPid(_ binding: HostElementBinding) -> pid_t? {
        guard let element = binding.element else {
            return nil
        }
        return HostAX.actualPid(of: element)
    }

    func currentDigestInput(_ binding: HostElementBinding) -> HostElementDigestInput? {
        guard let element = binding.element else {
            return nil
        }

        // §5.8 — a menu binding is rebuilt with no window to be relative to, so
        // this side suppresses the frame exactly as the walk did. Passing
        // `windowBounds` here regardless would recompute a frame the observation
        // never emitted, and `element_changed` / `changed: ["frame"]` would
        // refuse every menu dispatch.
        let node = HostAXNode(
            element: element,
            windowBounds: binding.isMenu ? nil : windowBounds,
            focusedElement: nil
        )
        return hostElementDigestInput(
            node: node,
            depth: binding.depth,
            actions: hostNormalizedActions(node.rawActionNames),
            // No traversal to fall back on here: this side reads one element, not
            // a tree. A live element always answers `liveAncestorRoles`.
            ancestorRoles: node.liveAncestorRoles ?? [],
            siblingIndex: HostAX.siblingIndex(of: element)
        )
    }

    func uniqueRefetch(_ binding: HostElementBinding) -> HostBindingRefetchResult {
        let matches = refreshedBindings(for: binding).filter {
            hostIsIdentityPreservingRefetch(recorded: binding, candidate: $0)
        }
        switch matches.count {
        case 0:
            return .missing
        case 1:
            return .unique(matches[0])
        default:
            return .ambiguous
        }
    }

    func uniqueWebContentEquivalent(_ binding: HostElementBinding) -> HostElementBinding? {
        guard binding.dispatchPid == binding.pid else {
            return nil
        }

        let deadline = Date(
            timeIntervalSinceNow: Double(limits.treeWalkCeilingMs) / 1000
        )
        for attempt in 0..<3 {
            let matches = refreshedBindings(for: binding, deadline: deadline).filter {
                hostIsWebContentEquivalent(recorded: binding, candidate: $0)
            }
            if matches.count == 1, let match = matches.first, match.dispatchPid != binding.pid {
                return match
            }
            if matches.count > 1 {
                return nil
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.075)
            }
        }
        return nil
    }

    private func refreshedBindings(
        for binding: HostElementBinding,
        deadline: Date? = nil
    ) -> [HostElementBinding] {
        let root: HostAXNode
        if binding.isMenu {
            guard let menu = HostAX.menuBar(pid: binding.pid) else {
                return []
            }
            root = HostAXNode(
                element: menu,
                windowBounds: nil,
                focusedElement: nil,
                dropsAppleMenu: true
            )
        } else {
            guard let window = HostAX.window(pid: binding.pid, windowId: 0, bounds: windowBounds) else {
                return []
            }
            root = HostAXNode(
                element: window,
                windowBounds: windowBounds,
                focusedElement: HostAX.focusedElement(pid: binding.pid)
            )
        }

        guard let startTime = hostProcessStartTime(pid: binding.pid) else {
            return []
        }

        return hostWalkTree(
            root: root,
            pid: binding.pid,
            processStartTime: startTime,
            tokenPrefix: "refetch",
            bounds: HostTreeWalkBounds(
                maxElements: binding.isMenu ? limits.maxMenuElements : limits.maxElements,
                maxDepth: limits.maxDepth,
                maxTextChars: limits.maxTextChars,
                deadline: deadline ?? Date(
                    timeIntervalSinceNow: Double(limits.treeWalkCeilingMs) / 1000
                )
            ),
            isMenu: binding.isMenu
        ).bindings
    }
}
