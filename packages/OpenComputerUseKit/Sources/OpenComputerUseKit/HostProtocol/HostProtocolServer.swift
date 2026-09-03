import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Request parameters
//
// Every params struct is `Decodable` with no optional-bag shapes. §5 says why:
// optional `app` *and* optional `windowId` in one object is how a real-machine
// failure happened, where the contract said "app or window_id" while the harness
// required both. A tagged union cannot express that disagreement.

struct HostHelloParams: Decodable {
    let `protocol`: String
    let hostPid: Int32
    let imageDir: String
    let allowGlobalPointer: Bool
}

struct HostSessionBeginParams: Decodable {
    let session: String
    let captureScope: HostCaptureScope
}

struct HostSessionParams: Decodable {
    let session: String
}

enum HostTargetResolutionSelector: Decodable {
    case application(app: String, intent: Intent)
    case window(windowId: CGWindowID)

    enum Intent: String, Decodable {
        case operate
        case launch
    }

    private enum Key: String, CodingKey {
        case kind
        case app
        case intent
        case windowId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "application":
            self = .application(
                app: try container.decode(String.self, forKey: .app),
                intent: try container.decode(Intent.self, forKey: .intent)
            )
        case "window":
            self = .window(
                windowId: CGWindowID(try container.decode(UInt32.self, forKey: .windowId))
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "target.kind"
            )
        }
    }
}

struct HostTargetResolveParams: Decodable {
    let target: HostTargetResolutionSelector
}

enum HostTargetSelector: Decodable, Equatable {
    case window(appId: String, pid: pid_t, processGeneration: String, windowId: CGWindowID)

    private enum Key: String, CodingKey {
        case kind
        case appId
        case pid
        case processGeneration
        case windowId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "window":
            let processGeneration = try container.decode(String.self, forKey: .processGeneration)
            guard
                processGeneration.hasPrefix("pst:"),
                let startTime = UInt64(processGeneration.dropFirst(4)),
                hostProcessGeneration(startTime) == processGeneration
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .processGeneration,
                    in: container,
                    debugDescription: "target.processGeneration"
                )
            }
            self = .window(
                appId: try container.decode(String.self, forKey: .appId),
                pid: try container.decode(Int32.self, forKey: .pid),
                processGeneration: processGeneration,
                windowId: CGWindowID(try container.decode(UInt32.self, forKey: .windowId))
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "target.kind"
            )
        }
    }
}

/// §5.8 — how much of the menu bar to walk.
///
/// A menu bar is not one size. TextEdit's is 369 elements and 157 ms; its window
/// is 16 elements and 58 ms. Asking for all of it on every observation makes the
/// menu 94% of what the model reads and 90% of what the observation costs, to
/// answer a question — "which menus are there" — that nine elements answer.
///
/// So the scope is named rather than assumed:
///
/// - `bar` walks the bar and its top-level items and stops. Nine elements, 5 ms.
///   It is what an observation carries by default, because a model that cannot
///   see the menu bar at all does not know to ask about it.
/// - `menu` walks one named menu in full while still listing every other item,
///   which is what a person does: you open 文件, you do not read all seven menus.
/// - `all` walks everything, for a host that wants the whole tree in one call.
struct HostMenuScope: Decodable {
    enum Kind: String, Decodable {
        case bar
        case menu
        case all
    }

    let scope: Kind
    /// Required by `menu` and rejected for the other two, rather than ignored:
    /// a `title` that silently does nothing reads as "there is no such menu".
    let title: String?
}

struct HostObserveParams: Decodable {
    let session: String
    let target: HostTargetSelector
    let includeImage: Bool?
    let maxElements: Int?
    let maxDepth: Int?
    let maxTextChars: Int?
    /// §5.8 — absent walks no menu at all.
    let menu: HostMenuScope?
}

struct HostPermissionsCheckParams: Decodable {
    let prompt: Bool?
}

struct HostAppsLaunchParams: Decodable {
    let session: String
    let app: String
    let waitForWindowMs: Int?
}

struct HostScreenCaptureParams: Decodable {
    let session: String
    /// §6.6 — optional. The model reaches this method through `CuAction`'s
    /// `screenshot` member, which exists precisely to ask for a picture without
    /// naming a target; requiring the field made every such request `-32602`.
    /// Absent means the main display, and the answer always names the display
    /// that was captured.
    let displayId: String?
}

struct HostObserveAfter: Decodable {
    let includeImage: Bool
    let settle: HostSettleMode
    /// §5.8 — absent is `false`, as it is on `observe`. It exists because a menu
    /// press changes what the *rest* of the menu will do: `文件 > 打开…` brings a
    /// document up, and with it `存储`, `导出为PDF…` and `关闭` all move from
    /// disabled to enabled. Without this the host would have to spend a whole
    /// second `observe` to see that, and that observe would supersede the frame
    /// the dispatch had just handed it.
    let menu: HostMenuScope?
}

struct HostDispatchElementParams: Decodable {
    let session: String
    let snapshotId: String
    let toolCallId: String
    let elementToken: String
    let expectElementDigest: String
    let strictness: HostStrictness?
    let occlusionPolicy: HostOcclusionPolicy?
    let action: HostElementAction
    let observeAfter: HostObserveAfter?
}

struct HostDispatchPointParams: Decodable {
    let session: String
    let snapshotId: String
    let toolCallId: String
    let expectWindowDigest: String
    let point: HostPoint
    let startPoint: HostPoint?
    let space: String
    let occlusionPolicy: HostOcclusionPolicy?
    let action: HostPointAction
    let observeAfter: HostObserveAfter?
}

struct HostDispatchKeyParams: Decodable {
    let session: String
    let snapshotId: String
    let toolCallId: String
    let focusToken: String
    let expectElementDigest: String
    /// §6.4 — absent means `require`, the check this method has always made.
    let focusPolicy: HostFocusPolicy?
    let action: HostKeyAction
    let observeAfter: HostObserveAfter?
}

struct HostCancelParams: Decodable {
    let id: Int
}

/// What the three dispatch methods have in common when they cannot be answered
/// with a result: the id to echo, and the tier the executor would have used.
/// §6.5 — `tier` on a refusal is that tier, which is why `path: none` pairs with
/// any of them.
protocol HostDispatchRequest {
    var toolCallId: String { get }
    var wouldUseTier: HostDispatchTier { get }
}

extension HostDispatchElementParams: HostDispatchRequest {
    var wouldUseTier: HostDispatchTier { .ax }
}

extension HostDispatchPointParams: HostDispatchRequest {
    var wouldUseTier: HostDispatchTier { .coordinateBackground }
}

extension HostDispatchKeyParams: HostDispatchRequest {
    var wouldUseTier: HostDispatchTier { .coordinateBackground }
}

extension HostElementAction: Decodable {
    private enum Key: String, CodingKey {
        case kind
        case button
        case count
        case value
        case text
        case action
        case direction
        case pages
        case position
        case size
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "click":
            let count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
            guard (1...3).contains(count) else {
                throw DecodingError.dataCorruptedError(forKey: .count, in: container, debugDescription: "action.count")
            }
            self = .click(
                button: try container.decodeIfPresent(HostMouseButton.self, forKey: .button) ?? .left,
                count: count
            )
        case "set_value":
            self = .setValue(try container.decode(String.self, forKey: .value))
        case "select_text":
            self = .selectText(try container.decode(String.self, forKey: .text))
        case "secondary_action":
            self = .secondaryAction(try container.decode(HostElementActionName.self, forKey: .action))
        case "scroll":
            let pages = try container.decodeIfPresent(Double.self, forKey: .pages) ?? 1
            guard pages.isFinite, pages > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .pages, in: container, debugDescription: "action.pages")
            }
            self = .scroll(direction: try container.decode(HostScrollDirection.self, forKey: .direction), pages: pages)
        case "move_window":
            // §6.1 — the executor does not clamp a window into a display, and
            // there is therefore nothing here to validate a position against: a
            // negative `y` is the ordinary way to name a display above the main
            // one on this machine, and off-screen is a request macOS answers for
            // itself. What is rejected is a number that is not a position.
            //
            // Unreachable through JSON, and kept anyway: `1e400` is not a
            // representable `Double` and Foundation rejects the whole document
            // rather than handing this an infinity. It stays for the reason
            // `postKeyEvent`'s unreachable stroke guard stays — the alternative
            // to refusing a non-finite position is writing one, and
            // `AXValueCreate` would take it.
            let position = try container.decode(HostPoint.self, forKey: .position)
            guard position.x.isFinite, position.y.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .position, in: container, debugDescription: "action.position")
            }
            self = .moveWindow(position)
        case "resize_window":
            // A negative extent is not a size. Zero is left alone: applications
            // clamp it to their own minimum — measured, TextEdit answered a
            // 10 × 10 request with 115 × 46 — and the readback is what says so.
            let size = try container.decode(HostSize.self, forKey: .size)
            guard size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .size, in: container, debugDescription: "action.size")
            }
            self = .resizeWindow(size)
        case "minimize_window":
            self = .minimizeWindow
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "action.kind")
        }
    }
}

extension HostPointAction: Decodable {
    private enum Key: String, CodingKey {
        case kind
        case count
        case direction
        case pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1

        switch try container.decode(String.self, forKey: .kind) {
        case "move":
            self = .move
        case "left_click":
            self = .leftClick(count: count)
        case "right_click":
            self = .rightClick(count: count)
        case "middle_click":
            self = .middleClick(count: count)
        case "double_click":
            self = .leftClick(count: 2)
        case "triple_click":
            self = .leftClick(count: 3)
        case "mouse_down":
            self = .mouseDown
        case "mouse_up":
            self = .mouseUp
        case "drag":
            self = .drag
        case "scroll":
            let pages = try container.decodeIfPresent(Double.self, forKey: .pages) ?? 1
            guard pages.isFinite, pages > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .pages, in: container, debugDescription: "action.pages")
            }
            self = .scroll(direction: try container.decode(HostScrollDirection.self, forKey: .direction), pages: pages)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "action.kind")
        }
    }
}

extension HostKeyAction: Decodable {
    private enum Key: String, CodingKey {
        case kind
        case text
        case key
        case modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "type":
            self = .type(try container.decode(String.self, forKey: .text))
        case "key":
            let name = try container.decode(String.self, forKey: .key)
            // §6.4 — a closed set of named keys plus single printable characters.
            // Anything else is `-32602` rather than a guess.
            guard hostKeyNameIsSupported(name) else {
                throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "action.key")
            }
            self = .key(
                name: name,
                modifiers: try container.decodeIfPresent([HostKeyModifier].self, forKey: .modifiers) ?? []
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "action.kind")
        }
    }
}

/// The named keys the executor will accept, plus single printable characters,
/// both answered by the stroke table in `HostKeyStroke.swift`: the set the wire
/// advertises is the set the dispatcher can post, and nothing keeps two copies
/// in step.

// MARK: - Response payloads

struct HostHelloResult: Encodable {
    let `protocol`: String
    let executor: Executor
    let pid: Int32
    let capabilities: HostCapabilities
    let limits: HostLimits

    struct Executor: Encodable {
        let name: String
        let version: String
        let commit: String
    }
}

struct HostSessionEndResult: Encodable {
    let released: HostSessionReleaseCounts
}

struct HostObserveResult: Encodable {
    let snapshot: HostSnapshotPayload
}

struct HostWindowListResult: Encodable {
    let windows: [Window]

    struct Window: Encodable {
        let pid: Int32
        let windowId: UInt32
        let appId: String
        let appName: String
        let title: String?
        let bounds: HostRect
        let layer: Int
        let zIndex: Int
        let onScreen: Bool
        let displayId: String?
    }
}

struct HostAppsListResult: Encodable {
    let apps: [App]

    struct App: Encodable {
        let appId: String
        let pid: Int32
        let name: String
        let windowCount: Int
        let running: Bool
    }
}

struct HostTargetResolveResult: Encodable {
    enum Resolution: String, Encodable {
        case resolved
        case missing
        case ambiguous
    }

    struct Target: Encodable {
        enum Kind: String, Encodable {
            case installed
            case running
        }

        let kind: Kind
        let appId: String
        let pid: Int32?
        let processGeneration: String?
        let windowId: UInt32?
    }

    let resolution: Resolution
    let target: Target?
}

struct HostPermissionsResult: Encodable {
    let accessibility: Bool
    let screenRecording: Bool
    let screenRecordingProbe: HostScreenRecordingProbe
}

struct HostAppsLaunchResult: Encodable {
    let pid: Int32
    /// §5.7 — the resolved `appId`. The request may name an app that is not
    /// running, and a display name is legal there precisely because such an app
    /// has no `appId` the caller could have learned; every later call uses this.
    let appId: String
    let name: String
    let foregroundTaken: Bool
    let windows: [LaunchedWindow]
    let waited: Waited

    struct LaunchedWindow: Encodable {
        let windowId: UInt32
        let title: String?
    }

    struct Waited: Encodable {
        let ms: Int
        let reason: HostLaunchWaitReason
    }
}

struct HostSettleReport: Encodable {
    let waitedMs: Int
    let quiesced: Bool
    let reason: HostSettleReason
}

struct HostDispatchResult: Encodable {
    let toolCallId: String
    let outcome: HostDispatchOutcome
    let tier: HostDispatchTier
    let path: HostDispatchPath
    let effect: HostDispatchEffect
    let verification: HostVerification
    let settle: HostSettleReport
    let snapshot: HostSnapshotPayload?
    /// §6.1 — an error *object*, the same shape as every other `error` on this
    /// wire. A bare code string here made the one field that reports a failed
    /// post-observation the only failure the host had to parse differently.
    let postObservationError: HostDomainErrorPayload?
}

struct HostScreenCaptureResult: Encodable {
    let image: HostImageReference
    let displayId: String
    let capturedAt: Int64
}

// MARK: - Server

/// The `maka.cu/3` executor. One reader, serial lanes, one response per request
/// id. Everything the host needs to reason about is a declared field; nothing is
/// inferred from a message string on either side.
public final class HostProtocolServer {
    let limits = HostLimits()
    private let capabilities = HostCapabilities()
    private let output: HostOutputWriter
    /// Every read of the live machine goes through this, so the §4 binding rules
    /// can be exercised without a desktop. See `HostSystemEnvironment`.
    let environment: HostSystemEnvironment
    private let lanes = HostLaneScheduler()
    let cancellations = HostCancellationRegistry()

    private let stateLock = NSLock()
    private var handshakeComplete = false
    private var shuttingDown = false
    private var allowGlobalPointer = false
    private var imageStore: HostImageStore?
    private var registry: HostSnapshotRegistry?
    private var hostPidWatchdog: DispatchSourceTimer?

    /// Exit code the caller should use once `run()` returns. §2 requires `78`
    /// after a protocol mismatch, and the host must not retry that classification.
    public private(set) var exitStatus: Int32 = 0

    public init(
        output: HostOutputWriter = HostOutputWriter(),
        environment: HostSystemEnvironment = HostLiveEnvironment()
    ) {
        self.output = output
        self.environment = environment
    }

    // MARK: Run loop

    public func run() {
        installSignalHandling()

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            handle(line: trimmed)

            if exitStatus == makaCuProtocolMismatchExitStatus {
                break
            }
        }

        beginShutdown()
        _ = lanes.waitForCompletion(timeout: .now() + .milliseconds(limits.shutdownGraceMs))
        shutdownSessions()
    }

    /// §11 — stop accepting work, and answer everything already queued rather
    /// than letting the grace deadline swallow the response. A request the
    /// executor has read owes exactly one response (§1), and one that is still
    /// sitting on a lane when the host asks us to stop has not been dispatched,
    /// so `aborted` is the truthful one.
    func beginShutdown() {
        stateLock.lock()
        shuttingDown = true
        stateLock.unlock()

        lanes.beginShutdown()
    }

    /// Split from `run()` so the framing, handshake gate and routing can be
    /// exercised line by line in tests.
    public func handle(line: String) {
        let data = Data(line.utf8)

        guard let header = try? HostProtocolCodec.decoder.decode(HostRequestHeader.self, from: data) else {
            emit(id: nil, rpcError: HostRPCError(.parseError))
            return
        }

        guard header.jsonrpc == "2.0", let method = header.method else {
            emit(id: header.id, rpcError: HostRPCError(.invalidRequest))
            return
        }

        if method == "$/cancel" {
            if let params = try? HostProtocolCodec.decoder.decode(HostRequestEnvelope<HostCancelParams>.self, from: data).params {
                cancellations.cancel(id: params.id)
            }
            return
        }

        guard let id = header.id else {
            // A notification we do not implement. §1 gives notifications no id and
            // no response, so silence is the whole contract.
            return
        }

        stateLock.lock()
        let isShuttingDown = shuttingDown
        let isHandshakeComplete = handshakeComplete
        stateLock.unlock()

        if isShuttingDown {
            emit(id: id, rpcError: HostRPCError(.shuttingDown))
            return
        }

        if method == "host.hello" {
            // Handled on the reader thread rather than a lane: `host.hello` MUST
            // be the first message on the connection, so nothing can be in flight
            // beside it, and deferring it would let the next request race the
            // handshake gate and get a spurious `-32001`.
            handleHello(id: id, data: data)
            return
        }

        guard isHandshakeComplete else {
            emit(id: id, rpcError: HostRPCError(.handshakeRequired))
            return
        }

        route(method: method, id: id, data: data)
    }

    private func route(method: String, id: Int, data: Data) {
        switch method {
        case "session.begin":
            enqueueControl(id: id, data: data, handler: handleSessionBegin)
        case "session.end":
            enqueueControl(id: id, data: data, handler: handleSessionEnd)
        case "permissions.check":
            enqueueControl(id: id, data: data, handler: handlePermissionsCheck)
        case "apps.list":
            lanes.enqueue(.control) { [weak self] in
                self?.handleAppsList(id: id)
            } ifShuttingDown: { [weak self] in
                self?.emit(id: id, failure: HostDomainError(.aborted))
            }
        case "target.resolve":
            enqueueControl(id: id, data: data, handler: handleTargetResolve)
        case "window.list":
            lanes.enqueue(.control) { [weak self] in
                self?.handleWindowList(id: id)
            } ifShuttingDown: { [weak self] in
                self?.emit(id: id, failure: HostDomainError(.aborted))
            }
        case "observe":
            enqueueTargetLane(id: id, data: data, handler: handleObserve)
        case "dispatch.element":
            enqueueTargetLane(id: id, data: data, handler: handleDispatchElement)
        case "dispatch.point":
            enqueueTargetLane(id: id, data: data, handler: handleDispatchPoint)
        case "dispatch.key":
            enqueueTargetLane(id: id, data: data, handler: handleDispatchKey)
        case "apps.launch":
            enqueueMisc(id: id, data: data, handler: handleAppsLaunch)
        case "screen.capture":
            enqueueMisc(id: id, data: data, handler: handleScreenCapture)
        case "capture.start", "capture.next", "capture.stop":
            // §10 — reserved. A *domain* result, never `-32601`, so feature
            // detection is a stable field read and the names can never be taken
            // by something else.
            lanes.enqueue(.control) { [weak self] in
                self?.emit(id: id, failure: HostDomainError(.notImplemented))
            } ifShuttingDown: { [weak self] in
                self?.emit(id: id, failure: HostDomainError(.aborted))
            }
        default:
            emit(id: id, rpcError: HostRPCError(.unknownMethod))
        }
    }

    // MARK: Lane helpers

    private func enqueueControl<Params: Decodable>(
        id: Int,
        data: Data,
        handler: @escaping (Int, Params) -> Void
    ) {
        guard let params = decode(Params.self, id: id, data: data) else {
            return
        }

        lanes.enqueue(.control) {
            handler(id, params)
        } ifShuttingDown: { [weak self] in
            self?.emitAborted(id: id, params: params)
        }
    }

    private func enqueueMisc<Params: Decodable>(
        id: Int,
        data: Data,
        handler: @escaping (Int, Params) -> Void
    ) {
        guard let params = decode(Params.self, id: id, data: data) else {
            return
        }

        lanes.enqueue(.misc) {
            handler(id, params)
        } ifShuttingDown: { [weak self] in
            self?.emitAborted(id: id, params: params)
        }
    }

    /// §9 — observes and dispatches against one window share a lane, so a
    /// dispatch can never overtake the observe that produced its snapshot.
    private func enqueueTargetLane<Params: Decodable>(
        id: Int,
        data: Data,
        handler: @escaping (Int, Params) -> Void
    ) {
        guard let params = decode(Params.self, id: id, data: data) else {
            return
        }

        lanes.enqueue(targetLane(for: params)) {
            handler(id, params)
        } ifShuttingDown: { [weak self] in
            self?.emitAborted(id: id, params: params)
        }
    }

    /// §11 — queued-but-unstarted work is answered with `aborted`, and a dispatch
    /// is answered on the arm §1.1 declares rather than as a bare error.
    private func emitAborted<Params>(id: Int, params: Params) {
        guard let dispatch = params as? HostDispatchRequest else {
            emit(id: id, failure: HostDomainError(.aborted))
            return
        }

        emit(
            id: id,
            toolCallId: dispatch.toolCallId,
            dispatchFailure: HostDomainError(.aborted),
            tier: dispatch.wouldUseTier
        )
    }

    private func targetLane<Params>(for params: Params) -> HostLaneScheduler.Lane {
        if let observe = params as? HostObserveParams,
           case let .window(_, pid, _, windowId) = observe.target {
            return .target(pid: pid, windowId: windowId)
        }

        // A dispatch names a snapshot rather than a window, and the snapshot knows
        // which window it came from.
        let snapshotId: String?
        switch params {
        case let element as HostDispatchElementParams:
            snapshotId = element.snapshotId
        case let point as HostDispatchPointParams:
            snapshotId = point.snapshotId
        case let key as HostDispatchKeyParams:
            snapshotId = key.snapshotId
        default:
            snapshotId = nil
        }

        if let snapshotId,
           let session = sessionId(of: params),
           let snapshot = try? currentRegistry().resolve(session: session, snapshotId: snapshotId, now: hostNowMs()).get() {
            return .target(pid: snapshot.pid, windowId: snapshot.windowId)
        }

        return .misc
    }

    private func sessionId<Params>(of params: Params) -> String? {
        switch params {
        case let element as HostDispatchElementParams:
            return element.session
        case let point as HostDispatchPointParams:
            return point.session
        case let key as HostDispatchKeyParams:
            return key.session
        case let observe as HostObserveParams:
            return observe.session
        default:
            return nil
        }
    }

    private func decode<Params: Decodable>(_ type: Params.Type, id: Int, data: Data) -> Params? {
        do {
            guard let params = try HostProtocolCodec.decoder.decode(HostRequestEnvelope<Params>.self, from: data).params else {
                emit(id: id, rpcError: HostRPCError.invalidParams("params"))
                return nil
            }
            return params
        } catch let error as DecodingError {
            emit(id: id, rpcError: HostRPCError.invalidParams(hostDecodingField(error)))
            return nil
        } catch {
            emit(id: id, rpcError: HostRPCError(.internalError))
            return nil
        }
    }

    // MARK: Emission

    func emit(id: Int?, rpcError: HostRPCError) {
        guard let line = try? HostProtocolCodec.rpcErrorResponse(id: id, error: rpcError) else {
            return
        }
        output.write(line)
    }

    func emit(id: Int?, failure: HostDomainError, toolCallId: String? = nil) {
        guard let line = try? HostProtocolCodec.failureResponse(id: id, error: failure, toolCallId: toolCallId) else {
            return
        }
        output.write(line)
    }

    /// §1.1 — the `ok: false` arm of a dispatch result carries `outcome`, `tier`,
    /// `path`, `effect` and `verification` beside the error. §6.5 fixes the
    /// pairing: `refused` means nothing was dispatched and takes `path: none`,
    /// while `failed` and `unknown` name the path that was attempted.
    func emit(
        id: Int,
        toolCallId: String,
        dispatchFailure: HostDomainError,
        outcome: HostDispatchOutcome = .refused,
        tier: HostDispatchTier,
        path: HostDispatchPath = .none,
        verdict: HostEffectVerdict = hostEffectNotChecked()
    ) {
        let payload = HostDispatchFailureResult(
            toolCallId: toolCallId,
            outcome: outcome,
            tier: tier,
            path: path,
            effect: verdict.effect,
            verification: verdict.verification,
            error: dispatchFailure
        )

        guard let line = try? HostProtocolCodec.dispatchFailureResponse(id: id, failure: payload) else {
            return
        }
        output.write(line)
    }

    func emit<Payload: Encodable>(id: Int?, payload: Payload) {
        do {
            output.write(try HostProtocolCodec.okResponse(id: id, payload: payload))
        } catch {
            emit(id: id, rpcError: HostRPCError(.internalError))
        }
    }

    // MARK: Handshake

    private func handleHello(id: Int, data: Data) {
        guard let params = decode(HostHelloParams.self, id: id, data: data) else {
            return
        }

        guard params.protocol == makaCuProtocolVersion else {
            // §2 — fatal and loud. Flush, then exit 78 so the host classifies the
            // start as `service_mismatch` and does not retry.
            emit(
                id: id,
                rpcError: HostRPCError(.protocolVersionMismatch, supportedProtocols: [makaCuProtocolVersion])
            )
            exitStatus = makaCuProtocolMismatchExitStatus
            return
        }

        let store = HostImageStore(
            directory: URL(fileURLWithPath: params.imageDir, isDirectory: true),
            budgetBytes: limits.imageDirBudgetBytes
        )

        do {
            try store.verifyWritable()
        } catch let error as HostRPCError {
            emit(id: id, rpcError: error)
            return
        } catch {
            emit(id: id, rpcError: HostRPCError(.internalError))
            return
        }

        stateLock.lock()
        imageStore = store
        registry = HostSnapshotRegistry(limits: limits) { [weak store] path in
            store?.delete(path: path)
        }
        allowGlobalPointer = params.allowGlobalPointer
        handshakeComplete = true
        stateLock.unlock()

        startHostPidWatchdog(hostPid: params.hostPid)

        emit(
            id: id,
            payload: HostHelloResult(
                protocol: makaCuProtocolVersion,
                executor: HostHelloResult.Executor(
                    name: "maka-cu",
                    version: resolvedOpenComputerUseVersion(),
                    commit: openComputerUseBuildCommit()
                ),
                pid: ProcessInfo.processInfo.processIdentifier,
                capabilities: capabilities,
                limits: limits
            )
        )
    }

    /// §2 — macOS has no `PDEATHSIG`. Without this poll an orphaned executor
    /// holding Accessibility survives a host crash.
    private func startHostPidWatchdog(hostPid: pid_t) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "maka-cu.host-watchdog"))
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard kill(hostPid, 0) != 0, errno == ESRCH else {
                return
            }

            self?.shutdownSessions()
            exit(0)
        }
        timer.resume()
        hostPidWatchdog = timer
    }

    private func installSignalHandling() {
        // §11 — stop reading new requests, let in-flight work finish inside the
        // grace period, end every session, exit 0. The host SIGKILLs after that.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue(label: "maka-cu.sigterm"))
        source.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            self.beginShutdown()
            _ = self.lanes.waitForCompletion(timeout: .now() + .milliseconds(self.limits.shutdownGraceMs))
            self.shutdownSessions()
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }

    private var sigtermSource: DispatchSourceSignal?

    private func shutdownSessions() {
        stateLock.lock()
        let registry = self.registry
        stateLock.unlock()

        guard let registry else {
            return
        }

        for session in registry.liveSessionIds() {
            registry.endSession(session)
        }
    }

    func currentRegistry() -> HostSnapshotRegistry {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let registry else {
            preconditionFailure("registry is only reachable after a completed handshake")
        }
        return registry
    }

    func currentImageStore() -> HostImageStore {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let imageStore else {
            preconditionFailure("image store is only reachable after a completed handshake")
        }
        return imageStore
    }

    func globalPointerAllowed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return allowGlobalPointer
    }

    // MARK: Sessions

    private func handleSessionBegin(id: Int, params: HostSessionBeginParams) {
        do {
            try currentRegistry().beginSession(params.session, captureScope: params.captureScope)
            emit(id: id, payload: HostEmptyPayload())
        } catch let error as HostRPCError {
            emit(id: id, rpcError: error)
        } catch {
            emit(id: id, rpcError: HostRPCError(.internalError))
        }
    }

    private func handleSessionEnd(id: Int, params: HostSessionParams) {
        // §3 also calls for removing any executor-drawn cursor. This executor
        // draws none: the host protocol runs without an AppKit run loop, and Maka
        // draws its own agent cursor precisely because a driver-drawn one outlived
        // the run that drew it. Reaching into `SoftwareCursorOverlay` from a lane
        // would deadlock on `DispatchQueue.main.sync` against a main thread parked
        // in `readLine`, so `released.streams` and the cursor are both nothing to
        // release rather than something we quietly skip.
        let released = currentRegistry().endSession(params.session)
        emit(id: id, payload: HostSessionEndResult(released: released))
    }

    // MARK: Reads

    private func handlePermissionsCheck(id: Int, params: HostPermissionsCheckParams) {
        // §5 — `prompt: false` MUST NOT raise a TCC dialog. The host calls this at
        // every action start because a user can revoke at any time, and a prompt
        // there would be a dialog storm.
        let diagnostics = environment.permissions()
        if params.prompt == true, !diagnostics.accessibilityTrusted {
            PermissionSupport.requestAccessibilityPrompt()
        }

        // The host currently prefers a live ScreenCaptureKit probe over the cached
        // boolean and has to guess which it got. This says.
        var probe = HostScreenRecordingProbe.notProbed
        if diagnostics.screenCaptureGranted {
            let probed = (try? BlockingAsyncBridge.run(timeout: 2) {
                try await SCShareableContent.current.displays.isEmpty == false
            }) ?? false
            probe = probed ? .captureSucceeded : .captureFailed
        }

        emit(
            id: id,
            payload: HostPermissionsResult(
                accessibility: diagnostics.accessibilityTrusted,
                screenRecording: diagnostics.screenCaptureGranted,
                screenRecordingProbe: probe
            )
        )
    }

    private func handleWindowList(id: Int) {
        let windows = environment.onScreenWindows().map {
            HostWindowListResult.Window(
                pid: $0.pid,
                windowId: $0.windowId,
                appId: $0.appId,
                appName: $0.appName,
                title: $0.title,
                bounds: HostRect($0.bounds),
                layer: $0.layer,
                zIndex: $0.zIndex,
                onScreen: $0.onScreen,
                displayId: $0.displayId
            )
        }

        emit(id: id, payload: HostWindowListResult(windows: windows))
    }

    private func handleAppsList(id: Int) {
        let windows = environment.onScreenWindows()
        let apps = environment.runningApps().map { app in
            HostAppsListResult.App(
                appId: app.appId,
                pid: app.pid,
                name: app.name,
                windowCount: windows.filter { $0.pid == app.pid && $0.layer == 0 }.count,
                running: app.running
            )
        }

        emit(id: id, payload: HostAppsListResult(apps: apps))
    }

    private func handleTargetResolve(id: Int, params: HostTargetResolveParams) {
        switch params.target {
        case .application(let app, .launch):
            switch environment.installedBundleIdentifiers(matching: app) {
            case .failure(let error):
                emit(id: id, failure: error)
            case .success(let bundleIds):
                let unique = Array(Set(bundleIds)).sorted()
                guard unique.count == 1, let bundleId = unique.first else {
                    emit(
                        id: id,
                        payload: HostTargetResolveResult(
                            resolution: unique.isEmpty ? .missing : .ambiguous,
                            target: nil
                        )
                    )
                    return
                }
                emit(
                    id: id,
                    payload: HostTargetResolveResult(
                        resolution: .resolved,
                        target: .init(
                            kind: .installed,
                            appId: bundleId,
                            pid: nil,
                            processGeneration: nil,
                            windowId: nil
                        )
                    )
                )
            }

        case .application(let app, .operate):
            let running = environment.runningApps().filter(\.running)
            let exact = running.filter { $0.appId == app }
            let matchingApps = exact.isEmpty
                ? running.filter { $0.name.caseInsensitiveCompare(app) == .orderedSame }
                : exact
            let matchingPids = Set(matchingApps.map(\.pid))
            resolveRunningTarget(
                id: id,
                windows: environment.onScreenWindows().filter {
                    matchingPids.contains($0.pid) && $0.layer == 0 && $0.onScreen
                }
            )

        case .window(let windowId):
            resolveRunningTarget(
                id: id,
                windows: environment.onScreenWindows().filter { $0.windowId == windowId }
            )
        }
    }

    private func resolveRunningTarget(id: Int, windows: [HostWindowInfo]) {
        guard windows.count == 1, let window = windows.first else {
            emit(
                id: id,
                payload: HostTargetResolveResult(
                    resolution: windows.isEmpty ? .missing : .ambiguous,
                    target: nil
                )
            )
            return
        }
        guard let startTime = environment.processStartTime(pid: window.pid) else {
            emit(
                id: id,
                payload: HostTargetResolveResult(resolution: .missing, target: nil)
            )
            return
        }
        emit(
            id: id,
            payload: HostTargetResolveResult(
                resolution: .resolved,
                target: .init(
                    kind: .running,
                    appId: window.appId,
                    pid: window.pid,
                    processGeneration: hostProcessGeneration(startTime),
                    windowId: window.windowId
                )
            )
        )
    }
}
