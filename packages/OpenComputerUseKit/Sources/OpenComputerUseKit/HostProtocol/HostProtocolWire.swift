import Foundation

/// Wire vocabulary for `maka.cu/3`, the protocol spoken between the Maka Electron
/// host and this executor. See `docs/HOST_PROTOCOL.md`.
///
/// Every enum here is a closed set on purpose. The protocol exists because the
/// previous surface answered with free-form prose that the host had to pattern
/// match; nothing in this file may grow an "other" case.

public let makaCuProtocolVersion = "maka.cu/3"

/// `EX_CONFIG`. §2 requires this exact status after a version mismatch so the
/// host can classify the start as `service_mismatch` and refuse to retry.
public let makaCuProtocolMismatchExitStatus: Int32 = 78

// MARK: - JSON-RPC error layer

/// §1.1: a JSON-RPC `error` means the request was unusable or the executor was
/// not in a state to consider it. It never describes the observed world.
public enum HostRPCErrorCode: Int, Sendable {
    case parseError = -32700
    case invalidRequest = -32600
    case unknownMethod = -32601
    case invalidParams = -32602
    case internalError = -32603
    case protocolVersionMismatch = -32000
    case handshakeRequired = -32001
    case sessionUnknown = -32002
    case shuttingDown = -32003

    public var message: String {
        switch self {
        case .parseError:
            return "parse_error"
        case .invalidRequest:
            return "invalid_request"
        case .unknownMethod:
            return "unknown_method"
        case .invalidParams:
            return "invalid_params"
        case .internalError:
            return "internal_error"
        case .protocolVersionMismatch:
            return "protocol_version_mismatch"
        case .handshakeRequired:
            return "handshake_required"
        case .sessionUnknown:
            return "session_unknown"
        case .shuttingDown:
            return "shutting_down"
        }
    }
}

public struct HostRPCError: Error, Equatable, Sendable {
    public let code: HostRPCErrorCode
    /// Only `-32000` carries data, and only the supported version list. §2.
    public let supportedProtocols: [String]?
    /// Names the offending parameter. Enum-free but never application content:
    /// these are protocol field names chosen by this file, not observed text.
    public let field: String?

    public init(_ code: HostRPCErrorCode, field: String? = nil, supportedProtocols: [String]? = nil) {
        self.code = code
        self.field = field
        self.supportedProtocols = supportedProtocols
    }

    public static func invalidParams(_ field: String) -> HostRPCError {
        HostRPCError(.invalidParams, field: field)
    }
}

// MARK: - Domain error layer

/// §1.1: domain failures are `result`s, not JSON-RPC errors. They are expected
/// outcomes the model must see, and they carry structured evidence.
public enum HostDomainErrorCode: String, Codable, Sendable, CaseIterable {
    case snapshotUnknown = "snapshot_unknown"
    case snapshotSpent = "snapshot_spent"
    case snapshotSuperseded = "snapshot_superseded"
    case snapshotExpired = "snapshot_expired"
    case snapshotEvicted = "snapshot_evicted"
    case elementUnknown = "element_unknown"
    case elementDigestMismatch = "element_digest_mismatch"
    case elementReleased = "element_released"
    case elementChanged = "element_changed"
    case processReplaced = "process_replaced"
    case elementNotActionable = "element_not_actionable"
    case elementDisabled = "element_disabled"
    case windowGone = "window_gone"
    case windowChanged = "window_changed"
    case windowOccluded = "window_occluded"
    case focusChanged = "focus_changed"
    case appNotFound = "app_not_found"
    case permissionMissing = "permission_missing"
    case screenLocked = "screen_locked"
    case physicalInputActive = "physical_input_active"
    case unsupportedAction = "unsupported_action"
    case invalidPoint = "invalid_point"
    case dispatchRefused = "dispatch_refused"
    case outcomeUnknown = "outcome_unknown"
    case aborted = "aborted"
    case notImplemented = "not_implemented"
    case captureFailed = "capture_failed"
    case imageWriteFailed = "image_write_failed"
    case responseTooLarge = "response_too_large"
    case timeout = "timeout"

    /// §1.2: the message is a fixed sentence chosen by the code. It never carries
    /// text belonging to the observed application, so there is nothing to redact.
    public var message: String {
        switch self {
        case .snapshotUnknown:
            return "the snapshot id is not known to this executor process"
        case .snapshotSpent:
            return "the snapshot was already consumed by a mutating dispatch"
        case .snapshotSuperseded:
            return "a later observation replaced this snapshot of the same window"
        case .snapshotExpired:
            return "the snapshot outlived its time to live"
        case .snapshotEvicted:
            return "the snapshot was evicted because the session holds too many"
        case .elementUnknown:
            return "the element token is not part of the quoted snapshot"
        case .elementDigestMismatch:
            return "the echoed digest is not the one this snapshot recorded for that token"
        case .elementReleased:
            return "the accessibility reference behind the element is no longer valid"
        case .elementChanged:
            return "the element no longer matches the snapshot it was bound to"
        case .processReplaced:
            return "the process that owned the element was replaced"
        case .elementNotActionable:
            return "the element does not expose the requested action"
        case .elementDisabled:
            return "the element is disabled"
        case .windowGone:
            return "the target window no longer exists"
        case .windowChanged:
            return "the target window no longer matches the snapshot it was bound to"
        case .windowOccluded:
            return "another window covers the target"
        case .focusChanged:
            return "the focused element is not the one the request named"
        case .appNotFound:
            return "no running application matches the request"
        case .permissionMissing:
            return "a required macOS permission is not granted"
        case .screenLocked:
            return "the screen is locked"
        case .physicalInputActive:
            return "the user is driving the physical input devices"
        case .unsupportedAction:
            return "the requested action is not supported for this target"
        case .invalidPoint:
            return "the point is outside the target window"
        case .dispatchRefused:
            return "the action was attempted and refused, and nothing happened"
        case .outcomeUnknown:
            return "the action was attempted and its outcome cannot be determined"
        case .aborted:
            return "the request was cancelled before dispatch"
        case .notImplemented:
            return "the method is reserved and not implemented in this protocol version"
        case .captureFailed:
            return "the screen capture did not produce an image"
        case .imageWriteFailed:
            return "the image could not be written to the image directory"
        case .responseTooLarge:
            return "the response does not fit within the negotiated size limit"
        case .timeout:
            return "the operation did not finish in time"
        }
    }
}

/// §1.2: `detail` carries enums and numbers only.
public enum HostDomainErrorDetail: Equatable, Sendable {
    case none
    /// §6.2 — which digest inputs stopped matching.
    case changed([HostElementDigestField])
    /// §6.3 — the path that would have been needed but is not permitted.
    case wouldRequirePath(HostDispatchPath)
    /// §7.5 — measured encoded size against the negotiated limit.
    case responseSize(bytes: Int, limit: Int)
    case missingPermission(HostPermissionKind)
}

public struct HostDomainError: Error, Equatable, Sendable {
    public let code: HostDomainErrorCode
    public let detail: HostDomainErrorDetail

    public init(_ code: HostDomainErrorCode, detail: HostDomainErrorDetail = .none) {
        self.code = code
        self.detail = detail
    }

    public var message: String { code.message }
}

public enum HostPermissionKind: String, Codable, Sendable {
    case accessibility
    case screenRecording = "screen_recording"
}

/// §4.3 — the closed set of digest inputs, reported back in `detail.changed`.
public enum HostElementDigestField: String, Codable, Sendable, CaseIterable {
    case role
    case subrole
    case axIdentifier
    case title
    case label
    case value
    case frame
    case actions
    case ancestors
    case siblingIndex
}

// MARK: - Naming an app

/// §5.1 — there is exactly one string that names an app on this wire: the bundle
/// identifier when the process has one, otherwise `pid:<n>`. Every producer goes
/// through this function so `apps.list`, `window.list`, `snapshot.target` and the
/// `apps.launch` result cannot spell the same process two ways.
public func hostAppId(bundleIdentifier: String?, pid: pid_t) -> String {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
        return "pid:\(pid)"
    }

    return bundleIdentifier
}

/// A monotonic process identity used to prevent PID reuse from changing an
/// already approved target.
public func hostProcessGeneration(_ startTime: UInt64) -> String {
    "pst:\(startTime)"
}

// MARK: - Dispatch vocabulary

/// §6.5. `tier` uses Maka's exact `COMPUTER_USE_DISPATCH_TIERS` vocabulary so the
/// host never has to guess a tier from a path name.
public enum HostDispatchTier: String, Codable, Sendable {
    case ax
    case semanticBackground = "semantic-background"
    case coordinateBackground = "coordinate-background"
}

public enum HostDispatchPath: String, Codable, Sendable {
    case axAction = "ax_action"
    case axAttribute = "ax_attribute"
    case axSelect = "ax_select"
    case cgEventPid = "cg_event_pid"
    case skylightPid = "skylight_pid"
    case cgEventGlobal = "cg_event_global"
    case none

    /// §6.3 — the pairing is fixed, and the host rejects anything outside it.
    /// `none` belongs to no tier because refusals report `tier` separately.
    public var tier: HostDispatchTier? {
        switch self {
        case .axAction, .axAttribute, .axSelect:
            return .ax
        case .cgEventPid, .skylightPid, .cgEventGlobal:
            return .coordinateBackground
        case .none:
            return nil
        }
    }
}

public enum HostDispatchOutcome: String, Codable, Sendable {
    case ok
    case refused
    case failed
    case unknown
}

public enum HostDispatchEffect: String, Codable, Sendable {
    case confirmed
    case unverifiable
    case suspectedNoop = "suspected_noop"
}

public enum HostVerificationMethod: String, Codable, Sendable {
    case none
    case actionResult = "action_result"
    case valueReadback = "value_readback"
    case selectionReadback = "selection_readback"
    case focusReadback = "focus_readback"
    case treeDelta = "tree_delta"
}

public struct HostVerification: Codable, Equatable, Sendable {
    public let method: HostVerificationMethod
    public let observedChange: Bool

    public init(method: HostVerificationMethod, observedChange: Bool) {
        self.method = method
        self.observedChange = observedChange
    }
}

/// §5 — normalised action names. The host never sees `AXPress`.
public enum HostElementActionName: String, Codable, Sendable, CaseIterable {
    case press
    case confirm
    case open
    case showMenu = "show_menu"
    case raise
    case cancel
    case pick
    case increment
    case decrement
    case scrollUp = "scroll_up"
    case scrollDown = "scroll_down"
    case scrollLeft = "scroll_left"
    case scrollRight = "scroll_right"

    /// Maps a raw AX action name onto the closed set. Unknown raw names are
    /// dropped rather than passed through: an action the host cannot name in the
    /// closed set is an action it can never request.
    public static func normalized(rawAXAction: String) -> HostElementActionName? {
        switch rawAXAction {
        case "AXPress":
            return .press
        case "AXConfirm":
            return .confirm
        case "AXOpen":
            return .open
        case "AXShowMenu":
            return .showMenu
        case "AXRaise":
            return .raise
        case "AXCancel":
            return .cancel
        case "AXPick":
            return .pick
        case "AXIncrement":
            return .increment
        case "AXDecrement":
            return .decrement
        case "AXScrollUpByPage":
            return .scrollUp
        case "AXScrollDownByPage":
            return .scrollDown
        case "AXScrollLeftByPage":
            return .scrollLeft
        case "AXScrollRightByPage":
            return .scrollRight
        default:
            return nil
        }
    }

    public var rawAXAction: String {
        switch self {
        case .press:
            return "AXPress"
        case .confirm:
            return "AXConfirm"
        case .open:
            return "AXOpen"
        case .showMenu:
            return "AXShowMenu"
        case .raise:
            return "AXRaise"
        case .cancel:
            return "AXCancel"
        case .pick:
            return "AXPick"
        case .increment:
            return "AXIncrement"
        case .decrement:
            return "AXDecrement"
        case .scrollUp:
            return "AXScrollUpByPage"
        case .scrollDown:
            return "AXScrollDownByPage"
        case .scrollLeft:
            return "AXScrollLeftByPage"
        case .scrollRight:
            return "AXScrollRightByPage"
        }
    }
}

public enum HostStrictness: String, Codable, Sendable {
    case element
    case window
}

public enum HostOcclusionPolicy: String, Codable, Sendable {
    case sameApp = "same_app"
    case any
    case none
}

/// §6.4 — what `dispatch.key` may do about focus before it posts.
///
/// `require` is the default because the executor never silently redirects a key:
/// a host that did not ask for focus to move gets the strict check it has always
/// had. `acquire` exists because the alternative the host was left with —
/// clicking the control first to focus it — is not a focus operation at all: a
/// click on a button presses it, and the model paid for a side effect it never
/// asked for.
public enum HostFocusPolicy: String, Codable, Sendable {
    case require
    case acquire
}

public enum HostSettleMode: String, Codable, Sendable {
    case none
    case quiesce
}

/// §6.1 — why the executor stopped waiting for the window to stop changing.
///
/// The three failing-to-quiesce arms are different facts about the window and the
/// host acts on them differently, which is why `ceiling` was split rather than
/// left to cover both:
///
/// - `ceiling` — two or more looks were compared, they differed, and the budget
///   ran out. The window was still moving when the executor gave up.
/// - `window_too_slow` — one look at this window costs more than the budget had
///   left, so the second look that is the only way to prove it stopped was never
///   affordable. Nothing is known about whether it settled, and waiting longer
///   under this budget cannot change that. Measured on macOS 26.5: one look at
///   System Settings' 337-element digest takes 2.18–2.22 s and one at a
///   1114–1225-element Finder window takes 3.16–3.62 s, against a 2.5 s budget —
///   so two looks at the Finder window, which is the minimum quiescence can be
///   proven in, is over 6 s.
public enum HostSettleReason: String, Codable, Sendable {
    case quiesced
    case ceiling
    case windowTooSlow = "window_too_slow"
    case notRequested = "not_requested"
}

public enum HostCaptureScope: String, Codable, Sendable {
    case window
    case desktop
}

public enum HostMouseButton: String, Codable, Sendable {
    case left
    case right
    case middle
}

public enum HostScrollDirection: String, Codable, Sendable {
    case up
    case down
    case left
    case right
}

public enum HostKeyModifier: String, Codable, Sendable, CaseIterable {
    case command
    case shift
    case option
    case control
    case fn
}

public enum HostImageFormat: String, Codable, Sendable {
    case png
    case jpeg
}

public enum HostLaunchWaitReason: String, Codable, Sendable {
    case windowAppeared = "window_appeared"
    case timeout
    case notRequested = "not_requested"
}

public enum HostScreenRecordingProbe: String, Codable, Sendable {
    case captureSucceeded = "capture_succeeded"
    case captureFailed = "capture_failed"
    case notProbed = "not_probed"
}

// MARK: - Limits and capabilities

/// §2 — every limit has a host consumer. The host must not hardcode a bound the
/// executor enforces, which is why they all travel in the handshake.
public struct HostLimits: Codable, Equatable, Sendable {
    public var snapshotsPerSession: Int = 8
    public var snapshotTtlMs: Int = 120_000
    public var maxElements: Int = 1500
    public var maxDepth: Int = 64
    public var maxTextChars: Int = 500
    public var maxResponseBytes: Int = 1_048_576
    public var settleCeilingMs: Int = 2500
    /// §5.2 — how long one `observe` may spend walking the Accessibility tree,
    /// across every attempt §7.5 makes.
    ///
    /// Chosen against two numbers that are not ours. The host gives a request
    /// 20 s and answers an overrun by cancelling and tearing the executor down,
    /// and a window capture may already have spent 5 s of that before the walk
    /// starts; 6 s leaves the slowest observation possible here at 11 s, and the
    /// slowest dispatch — settle 2.5 s, capture 5 s, then the `observeAfter`
    /// walk — at 13.5 s.
    ///
    /// The other number is what a healthy window costs. Measured on macOS 26.5:
    /// Calculator 65 elements in 0.54 s, Font Book 234 in 1.74 s, Safari 369 in
    /// 0.80 s, an Electron window 1292 in 1.03 s. The slowest complete walk was
    /// 1.74 s, so 6 s is more than three times the worst ordinary case and no
    /// ordinary observation is cut. What it does cut is the pathological one: an
    /// open or save panel, hosted in another process, read at 23.6 ms per
    /// element and rising — 35 s for 1500 elements, which is not an observation
    /// the host will ever see the end of.
    public var treeWalkCeilingMs: Int = 6000
    /// §5.8 — how many elements one menu bar observation may carry.
    ///
    /// Its own bound rather than a share of `maxElements`, because the two
    /// compete and the competition has a wrong winner. Measured on macOS 26.5,
    /// whole menu bars with the Apple menu excluded: Calculator 141, System
    /// Settings 164, Stickies 219, Obsidian 234, Finder 274, TextEdit 287,
    /// Preview 331, VS Code 393. Against the same applications' windows:
    /// TextEdit 13 elements, Preview 25, Calculator 65, Finder **1711**.
    ///
    /// So a shared budget fails at both ends. TextEdit's observation would be 96%
    /// menu, burying the thirteen elements the host actually asked about; and
    /// Finder's window already exceeds `maxElements` on its own, so the menu
    /// would be cut to nothing — in the application whose menu bar carries `前往`,
    /// `显示 > 排序方式` and every file operation there is. The applications with
    /// the most window to describe are the ones whose menus matter most, which is
    /// exactly the case a shared budget starves.
    ///
    /// 500 clears the largest measured menu by 27%. It is not a request
    /// parameter: half a menu tree is not half as useful the way half a window
    /// tree is — a path the model cannot see the end of is a path it cannot take
    /// — so a host that wants less menu asks for none.
    public var maxMenuElements: Int = 500
    /// §5.8 — and how long it may spend reading them, carved out of
    /// `treeWalkCeilingMs` rather than added to it.
    ///
    /// Element count is not a proxy for time — the reason `treeWalkCeilingMs`
    /// exists — and it is no more of one here. Measured cold, first read after
    /// launch: Finder's 333 in 118 ms, VS Code's 452 in 159 ms, Calculator's 200
    /// in 265 ms, TextEdit's 346 in 428 ms, Preview's 390 in 522 ms; warm, half
    /// of that. 1500 ms is nearly three times the slowest cold read and leaves at
    /// least 4.5 s of the walk budget to the window, which is the part that can
    /// be pathological: a Finder window measured 1711 elements in 5.22 s.
    public var menuWalkCeilingMs: Int = 1500
    public var shutdownGraceMs: Int = 3000
    public var imageDirBudgetBytes: Int = 268_435_456

    public init() {}
}

/// What this executor will actually do. Anything it would always refuse is
/// absent: a capability the host can read but never use is worse than a missing
/// one, because the host has no way to find out except by trying.
///
/// `mouse_down` / `mouse_up` are therefore not advertised — a half click has no
/// target-bound form that survives the executor's own event source going away
/// between the two halves — and `jpeg` waits for the capture stream that needs it.
/// `unminimize_window` is absent, and it is the one absence worth naming here
/// because the action plainly exists on the machine.
///
/// The reason recorded here used to be that writing `AXMinimized = false`
/// activates the application. That is **not** what this machine does: sampling
/// the frontmost pid at 100 Hz for three seconds after the write, across
/// Calculator, TextEdit and Preview, 900 samples caught the foreground moving
/// zero times. The earlier measurement is left named rather than deleted
/// because it was taken through the executor's whole dispatch path and this one
/// was not, and the two have not been reconciled.
///
/// The reason it is absent is simpler and is not in doubt: **a minimized window
/// is not in the window list**. `CGWindowListCopyWindowInfo` is asked for
/// `.optionOnScreenOnly`, a minimized window is not on screen, and measured
/// end to end — `list_apps` drops to `windowCount: 0` and `observe` answers
/// `target_missing` the moment `minimize_window` succeeds. There is nothing
/// left for an unminimize to address.
///
/// Closing that needs the window list to carry off-screen windows, and the
/// unfiltered list is not a drop-in: 213 layer-0 windows against 17 on screen, and
/// `kCGWindowIsOnscreen` is absent from its entries, so there is no field to
/// separate the two. The honest alternative — enumerate `AXWindows` per pid and
/// match them back to `CGWindowID` — has no public API for that mapping, which
/// is the actual piece of work. §14 carries it.
///
/// Until then `minimize_window` is a one-way door, and the host says so.
public struct HostCapabilities: Codable, Equatable, Sendable {
    public var captureStream: Bool = false
    public var elementActions: [String] = [
        "click", "set_value", "select_text", "secondary_action", "scroll",
        "move_window", "resize_window", "minimize_window",
    ]
    public var pointActions: [String] = []
    public var keyActions: [String] = ["type", "key"]
    public var imageFormats: [HostImageFormat] = [.png]

    public init() {}
}

// MARK: - Geometry on the wire

public struct HostRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct HostPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// §6.1 — the extent half of a window frame, separate from `HostRect` because
/// `resize_window` names a size and nothing else. Reusing `HostRect` with an
/// origin the executor is required to ignore is the optional-bag shape the params
/// structs already refuse: a field that is present and disregarded is a field the
/// caller believes it set.
public struct HostSize: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}
