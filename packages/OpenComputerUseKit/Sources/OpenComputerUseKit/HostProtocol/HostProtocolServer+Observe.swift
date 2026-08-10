import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public func hostNowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

/// Names the offending field for `-32602` without leaking a decoder's prose.
func hostDecodingField(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, _):
        return key.stringValue
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
        if !context.debugDescription.isEmpty, context.codingPath.isEmpty {
            return context.debugDescription
        }
        return context.codingPath.last?.stringValue ?? "params"
    @unknown default:
        return "params"
    }
}

// MARK: - Observation and dispatch

extension HostProtocolServer {
    // MARK: observe

    func handleObserve(id: Int, params: HostObserveParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        if let bound = validateObserveBounds(id: id, params: params) {
            emit(id: id, rpcError: bound)
            return
        }

        switch buildSnapshot(
            session: params.session,
            target: params.target,
            includeImage: params.includeImage ?? true,
            menuScope: params.menu,
            maxElements: params.maxElements ?? limits.maxElements,
            maxDepth: params.maxDepth ?? limits.maxDepth,
            maxTextChars: params.maxTextChars ?? limits.maxTextChars
        ) {
        case .success(let snapshot):
            currentRegistry().register(snapshot)
            emit(id: id, payload: HostObserveResult(snapshot: snapshot.payload))
        case .failure(let error):
            emit(id: id, failure: error)
        }
    }

    /// §5 — a value above the limit is `-32602`, not a silent clamp. Clamping is
    /// how a host ends up believing it asked for a bound the executor ignored.
    private func validateObserveBounds(id: Int, params: HostObserveParams) -> HostRPCError? {
        if let maxElements = params.maxElements, maxElements < 1 || maxElements > limits.maxElements {
            return HostRPCError.invalidParams("maxElements")
        }
        if let maxDepth = params.maxDepth, maxDepth < 1 || maxDepth > limits.maxDepth {
            return HostRPCError.invalidParams("maxDepth")
        }
        if let maxTextChars = params.maxTextChars, maxTextChars < 1 || maxTextChars > limits.maxTextChars {
            return HostRPCError.invalidParams("maxTextChars")
        }
        if let menu = params.menu, let reason = hostMenuScopeRejection(menu) {
            return reason
        }
        return nil
    }

    /// §5.8 — `title` belongs to `menu` and to nothing else.
    ///
    /// Ignoring a `title` on `all` would be indistinguishable, from the host's
    /// side, from a menu whose name it got wrong: both come back with the whole
    /// tree. Ignoring a missing one on `menu` is worse — the answer is every bar
    /// item and no contents, which reads exactly like "that menu is empty".
    func hostMenuScopeRejection(_ menu: HostMenuScope) -> HostRPCError? {
        switch menu.scope {
        case .menu:
            return (menu.title ?? "").isEmpty ? HostRPCError.invalidParams("menu.title") : nil
        case .bar, .all:
            return menu.title == nil ? nil : HostRPCError.invalidParams("menu.title")
        }
    }

    func requireSession(id: Int, session: String) -> Bool {
        guard currentRegistry().isSessionLive(session) else {
            emit(id: id, rpcError: HostRPCError(.sessionUnknown))
            return false
        }
        return true
    }

    /// The one place a snapshot is produced. Both `observe` and every
    /// `observeAfter` go through it, so a post-dispatch frame is the same shape,
    /// under the same bounds, as one the host asked for directly.
    func buildSnapshot(
        session: String,
        target: HostTargetSelector,
        includeImage: Bool,
        menuScope: HostMenuScope?,
        maxElements: Int,
        maxDepth: Int,
        maxTextChars: Int
    ) -> Result<HostSnapshot, HostDomainError> {
        if environment.screenIsLocked() {
            return .failure(HostDomainError(.screenLocked))
        }

        let diagnostics = environment.permissions()
        guard diagnostics.accessibilityTrusted else {
            return .failure(HostDomainError(.permissionMissing, detail: .missingPermission(.accessibility)))
        }

        let windows = environment.onScreenWindows()
        let resolved: HostWindowInfo
        switch target {
        case .window(let pid, let windowId):
            guard let match = windows.first(where: { $0.pid == pid && $0.windowId == windowId }) else {
                return .failure(HostDomainError(.windowGone))
            }
            resolved = match
        case .app(let appId):
            // §5.2 — the executor resolves `{ "kind": "app" }`, and it resolves it
            // by exact `appId` against what is *already running*. `observe` is a
            // read: it never launches and never activates.
            let app: HostRunningApp
            switch hostResolveAppTarget(appId: appId, in: environment.runningApps()) {
            case .success(let match):
                app = match
            case .failure(let error):
                return .failure(error)
            }

            // `{ "kind": "app" }` resolves to the app's frontmost usable window
            // and is ambiguous by design; `{ "kind": "window" }` is exact. The
            // window list is front-to-back, so the first match is the frontmost.
            guard let match = windows.first(where: { $0.pid == app.pid && $0.layer == 0 }) else {
                return .failure(HostDomainError(.windowGone))
            }
            resolved = match
        }

        var windowElement = environment.windowElement(
            pid: resolved.pid,
            windowId: resolved.windowId,
            bounds: resolved.bounds
        )
        if windowElement == nil {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            repeat {
                Thread.sleep(forTimeInterval: 0.01)
                windowElement = environment.windowElement(
                    pid: resolved.pid,
                    windowId: resolved.windowId,
                    bounds: resolved.bounds
                )
            } while windowElement == nil
                && ProcessInfo.processInfo.systemUptime < deadline
        }
        guard let windowElement else {
            return .failure(HostDomainError(.windowGone))
        }

        guard let startTime = hostProcessStartTime(pid: resolved.pid) else {
            return .failure(HostDomainError(.processReplaced))
        }

        var image: HostImageReference?
        if includeImage {
            let scope = currentRegistry().captureScope(of: session) ?? .window
            switch HostCapture.captureWindow(windowId: resolved.windowId, scope: scope) {
            case .success(let captured):
                switch currentImageStore().writePNG(
                    captured,
                    namePrefix: "snap",
                    logicalWidth: resolved.bounds.width
                ) {
                case .success(let reference):
                    image = reference
                case .failure(let error):
                    return .failure(error)
                }
            case .failure(let error):
                return .failure(error)
            }
        }

        let snapshotId = currentRegistry().nextSnapshotId()
        let focusedElement = environment.focusedElement(pid: resolved.pid)
        let capturedAt = hostNowMs()

        // §5.2 — one deadline for the whole observation, taken here rather than
        // inside the walk, because §7.5 runs the walk again for every halving of
        // `maxElements` and four walks each given the whole budget is four times
        // the budget. The clock starts after the capture, which has a ceiling of
        // its own (`HostCapture.timeout`), so the two ceilings add rather than
        // overlap and the sum still has to fit the host's request deadline.
        let walkDeadline = Date(timeIntervalSinceNow: Double(limits.treeWalkCeilingMs) / 1000)

        // §5.8 — the menu bar is walked first, once, and outside the fit loop
        // below.
        //
        // *First*, because the two walks share one deadline and only one of them
        // has a bounded cost. Every menu measured came back in 118–522 ms cold,
        // and its own ceiling caps it at 1500; a window has no such ceiling — a
        // Finder window measured 5.22 s for 1711 elements, and an open panel
        // reads at 23.6 ms an element with no limit at all. Walking the window
        // first would mean the applications with the largest windows never got a
        // menu, and those are the same applications whose menus carry the work.
        //
        // *Once*, because §7.5 may rebuild the payload four times to fit the byte
        // limit, and the menu does not depend on the budget it halves: rebuilding
        // it would spend up to four menu walks to produce four identical trees.
        // The menu is also not what overruns `maxResponseBytes` — 500 elements
        // with no frame encode to about 125 KB against a 1 MB limit — so shrinking
        // the window is the whole of the remedy.
        let menuWalk = menuScope.flatMap { scope in
            walkMenuBar(
                pid: resolved.pid,
                processStartTime: startTime,
                snapshotId: snapshotId,
                scope: scope,
                maxDepth: maxDepth,
                maxTextChars: maxTextChars,
                deadline: min(walkDeadline, Date(timeIntervalSinceNow: Double(limits.menuWalkCeilingMs) / 1000))
            )
        }

        var checkedWebContentReadiness = false
        let walk = { (elementBudget: Int) -> HostTreeWalkResult in
            var result = hostWalkTree(
                root: HostAXNode(
                    element: windowElement,
                    windowBounds: resolved.bounds,
                    focusedElement: focusedElement
                ),
                pid: resolved.pid,
                processStartTime: startTime,
                tokenPrefix: snapshotId,
                bounds: HostTreeWalkBounds(
                    maxElements: elementBudget,
                    maxDepth: maxDepth,
                    maxTextChars: maxTextChars,
                    deadline: walkDeadline
                )
            )
            if !checkedWebContentReadiness {
                checkedWebContentReadiness = true
                let hasWebArea = result.elements.contains { $0.role == "AXWebArea" }
                if !hasWebArea, self.environment.webContentProcess(pid: resolved.pid) != nil {
                    // A fresh WKWebView can publish its XPC process before its AX
                    // subtree. The first walk is what wakes that bridge; one
                    // bounded reread keeps the host mirror out of the model.
                    Thread.sleep(forTimeInterval: 0.25)
                    result = hostWalkTree(
                        root: HostAXNode(
                            element: windowElement,
                            windowBounds: resolved.bounds,
                            focusedElement: focusedElement
                        ),
                        pid: resolved.pid,
                        processStartTime: startTime,
                        tokenPrefix: snapshotId,
                        bounds: HostTreeWalkBounds(
                            maxElements: elementBudget,
                            maxDepth: maxDepth,
                            maxTextChars: maxTextChars,
                            deadline: walkDeadline
                        )
                    )
                }
            }
            return result
        }

        let selectedText = focusedElement
            .flatMap(HostAX.selectedText)
            .map { text -> HostSelectedText in
                let truncated = hostTruncate(text, limit: maxTextChars)
                return HostSelectedText(text: truncated.text ?? "", truncated: truncated.wasTruncated)
            }

        let obscuring = HostWindowInventory.obscuringRects(above: resolved, in: windows).map(HostRect.init)
        let displays = HostWindowInventory.displays()
        let previousSnapshot = currentRegistry().latestDifferenceBaseline(
            session: session,
            pid: resolved.pid,
            windowId: resolved.windowId
        )

        let fitted = hostFitResponse(
            maxElements: maxElements,
            limitBytes: limits.maxResponseBytes
        ) { budget -> (payload: (HostSnapshotPayload, HostTreeWalkResult, HostObservationRevision), encoded: Data) in
            let rawResult = hostRemovingShadowedWebMirrors(walk(budget))
            let currentRevision = hostObservationRevision(from: rawResult.elements)
            let appendResult = previousSnapshot.map {
                hostAppendObservationRevision(
                    previous: $0.observationRevision,
                    current: currentRevision
                )
            }
            let revision = appendResult?.revision
                ?? hostAssignRootStableIds(currentRevision)
            let result = hostApplyingStableIds(rawResult, revision: revision)
            let difference = appendResult.map {
                hostObservationDifferencePayload(
                    baseSnapshotId: previousSnapshot!.id,
                    appendResult: $0,
                    fullLineCount: result.elements.count
                )
            }
            let windowDigest = hostWindowDigest(
                elementDigests: result.elements.map(\.digest),
                bounds: resolved.bounds,
                title: resolved.title
            )

            let payload = HostSnapshotPayload(
                snapshotId: snapshotId,
                capturedAt: capturedAt,
                target: HostWindowTarget(
                    pid: resolved.pid,
                    windowId: resolved.windowId,
                    appId: resolved.appId,
                    appName: resolved.appName,
                    title: resolved.title,
                    bounds: HostRect(resolved.bounds),
                    layer: resolved.layer,
                    zIndex: resolved.zIndex,
                    displayId: resolved.displayId
                ),
                windowDigest: windowDigest,
                focusedElementToken: result.focusedToken,
                selectedText: selectedText,
                image: image,
                displays: displays,
                obscuringRects: obscuring,
                elements: result.elements,
                truncated: result.truncated,
                difference: difference,
                menu: menuWalk?.observation
            )

            let encoded = (try? HostProtocolCodec.encoder.encode(payload)) ?? Data()
            return ((payload, result, revision), encoded)
        }

        switch fitted {
        case .failure(let error):
            if let path = image?.path {
                currentImageStore().delete(path: path)
            }
            return .failure(error)
        case .success(let fit):
            let (payload, walkResult, observationRevision) = fit.payload
            return .success(
                HostSnapshot(
                    id: snapshotId,
                    session: session,
                    pid: resolved.pid,
                    windowId: resolved.windowId,
                    capturedAt: capturedAt,
                    windowDigest: payload.windowDigest,
                    payload: payload,
                    // §5.8 — menu bindings join the same dictionary, so
                    // `dispatch.element` resolves a menu token through the one
                    // lookup §4.2 allows. Their tokens cannot collide with the
                    // window's: the two walks are given different prefixes.
                    bindings: walkResult.bindings + (menuWalk?.bindings ?? []),
                    imagePath: image?.path,
                    observationRevision: observationRevision
                )
            )
        }
    }

    /// §5.8 — one menu bar, read from the application element, under its own
    /// element bound and its own deadline.
    ///
    /// Returns `nil` for an application with no menu bar at all, which is how the
    /// payload distinguishes "there is none" from "there is one and it is empty":
    /// the second comes back as a single root element with no children, because
    /// the walk always emits its root.
    private func walkMenuBar(
        pid: pid_t,
        processStartTime: UInt64,
        snapshotId: String,
        scope: HostMenuScope,
        maxDepth: Int,
        maxTextChars: Int,
        deadline: Date
    ) -> (observation: HostMenuObservation, bindings: [HostElementBinding])? {
        guard let root = environment.menuBarNode(pid: pid) else {
            return (HostMenuObservation(
                elements: [],
                truncated: HostSnapshotTruncation(elements: false, depth: false)
            ), [])
        }

        let result = hostWalkTree(
            root: root,
            pid: pid,
            processStartTime: processStartTime,
            // A prefix of its own, so a menu token and a window token from the
            // same snapshot can never be the same string. §4.2 forbids parsing an
            // index back out of a token, so the shape of the prefix is not a
            // contract — only its uniqueness within the snapshot is.
            tokenPrefix: "\(snapshotId)_menu",
            bounds: HostTreeWalkBounds(
                maxElements: limits.maxMenuElements,
                // `bar` stops one level below the bar, and stopping by depth is
                // the walk's own bound, so `truncated.depth` comes back true. It
                // is true: there is more menu below. The host says what it means.
                maxDepth: scope.scope == .bar ? min(maxDepth, 2) : maxDepth,
                maxTextChars: maxTextChars,
                deadline: deadline
            ),
            isMenu: true,
            // Depth 1 is a top-level bar item — the walk is rooted at the bar
            // itself. Every one of them is still emitted; only the named one is
            // opened.
            expands: { node, depth in
                guard scope.scope == .menu, depth == 1 else {
                    return true
                }
                return node.title == scope.title || node.label == scope.title
            }
        )

        // `focusedToken` is deliberately dropped. The snapshot has one focused
        // element and it is the window's; a menu item is never it, and a second
        // producer for that field is a second thing to keep consistent.
        return (
            HostMenuObservation(elements: result.elements, truncated: result.truncated),
            result.bindings
        )
    }

    // MARK: dispatch.element

    func handleDispatchElement(id: Int, params: HostDispatchElementParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        // §6.5 — the tier a refusal reports is the tier the executor would have
        // used, which for an element dispatch is always `ax`.
        func refuse(_ error: HostDomainError) {
            emit(id: id, toolCallId: params.toolCallId, dispatchFailure: error, tier: .ax)
        }

        let registry = currentRegistry()
        let snapshot: HostSnapshot
        switch registry.resolve(session: params.session, snapshotId: params.snapshotId, now: hostNowMs()) {
        case .success(let resolved):
            snapshot = resolved
        case .failure(let error):
            refuse(error)
            return
        }

        // §6.2 — three situations, three codes. A token this snapshot never
        // minted is the host quoting the wrong frame; a token it did mint,
        // carrying an echo it never recorded, is the host pairing a token from
        // one snapshot with a digest from another. Folding the second into
        // `element_unknown` told the host "stale frame" and it re-observed, then
        // echoed the same wrong digest again.
        guard let binding = snapshot.binding(for: params.elementToken) else {
            refuse(HostDomainError(.elementUnknown))
            return
        }

        guard binding.digest == params.expectElementDigest else {
            refuse(HostDomainError(.elementDigestMismatch))
            return
        }

        if cancellations.isCancelledBeforeDispatch(id: id) {
            refuse(HostDomainError(.aborted))
            return
        }

        let windows = environment.onScreenWindows()
        guard let window = windows.first(where: { $0.pid == snapshot.pid && $0.windowId == snapshot.windowId }) else {
            refuse(HostDomainError(.windowGone))
            return
        }

        let probe = environment.bindingProbe(windowBounds: window.bounds)
        var effectiveBinding = binding
        var promotedToWebContent = false
        if let failure = hostVerifyBinding(binding, probe: probe) {
            // Renderer layout can move a still-live AX object between observe
            // and dispatch. Only a frame-only change may use the same strict,
            // unique identity-preserving refetch as a released reference.
            let frameOnlyWebContentChange =
                binding.dispatchPid != binding.pid
                &&
                failure.code == .elementChanged
                && failure.detail == .changed([.frame])
            guard failure.code == .elementReleased || frameOnlyWebContentChange else {
                refuse(failure)
                return
            }

            switch probe.uniqueRefetch(binding) {
            case .unique(let replacement):
                effectiveBinding = replacement
                promotedToWebContent =
                    replacement.dispatchPid != replacement.pid
            case .missing:
                refuse(failure)
                return
            case .ambiguous:
                refuse(HostDomainError(.elementChanged))
                return
            }
        } else {
            let webContentMatches = snapshot.bindings.values.filter {
                hostIsWebContentEquivalent(recorded: binding, candidate: $0)
            }
            if webContentMatches.count > 1 {
                refuse(HostDomainError(.elementChanged))
                return
            }
            if let webContent = webContentMatches.first {
                let currentWebContent: HostElementBinding
                if webContent.dispatchPid == binding.pid {
                    guard let resolved = probe.uniqueWebContentEquivalent(binding) else {
                        refuse(HostDomainError(.elementChanged))
                        return
                    }
                    currentWebContent = resolved
                } else {
                    currentWebContent = webContent
                }
                if let failure = hostVerifyBinding(currentWebContent, probe: probe) {
                    let frameOnlyChange =
                        failure.code == .elementChanged
                        && failure.detail == .changed([.frame])
                    guard failure.code == .elementReleased || frameOnlyChange else {
                        refuse(failure)
                        return
                    }
                    switch probe.uniqueRefetch(currentWebContent) {
                    case .unique(let replacement):
                        effectiveBinding = replacement
                        promotedToWebContent = true
                    case .missing:
                        refuse(failure)
                        return
                    case .ambiguous:
                        refuse(HostDomainError(.elementChanged))
                        return
                    }
                } else {
                    effectiveBinding = currentWebContent
                    promotedToWebContent = true
                }
            } else if let webContent = probe.uniqueWebContentEquivalent(binding) {
                if let failure = hostVerifyBinding(webContent, probe: probe) {
                    refuse(failure)
                    return
                }
                effectiveBinding = webContent
                promotedToWebContent = true
            }
        }

        // §6.1 `strictness: "window"` — the only defence against recycled row
        // views, at the cost of refusing on any change anywhere in the window.
        if params.strictness == .window {
            let current = hostRecomputeWindowDigest(snapshot: snapshot, window: window, probe: probe)
            guard current == snapshot.windowDigest else {
                refuse(HostDomainError(.windowChanged))
                return
            }
        }

        // §6.1 — occlusion asks whether the pixel about to be acted on belongs to
        // somebody else. A window action acts on no pixel: it moves the window
        // and everything drawn in it, sheet included, so a window with something
        // stacked over it is exactly the window a model is asking to move.
        // Applying the check here would also refuse window management on every
        // application `apps.launch` started, because those begin at the bottom of
        // the z-order — the defect §6.1 already had to fix once for `same_app`.
        if !params.action.addressesTheWindowItself, let frame = effectiveBinding.observed.frame?.cgRect {
            let center = CGPoint(
                x: window.bounds.minX + frame.midX,
                y: window.bounds.minY + frame.midY
            )
            let obscuring = windows
                .filter { $0.layer == 0 && $0.zIndex > window.zIndex && $0.windowId != window.windowId }
                .filter { !HostWindowInventory.isFullScreenDockSurface($0) }
                .map { (pid: $0.pid, rect: $0.bounds) }

            if hostIsOccluded(
                policy: params.occlusionPolicy ?? .sameApp,
                targetPid: snapshot.pid,
                targetPoint: center,
                obscuringWindows: obscuring
            ) {
                refuse(HostDomainError(.windowOccluded))
                return
            }
        }

        guard effectiveBinding.observed.enabled else {
            refuse(HostDomainError(.elementDisabled))
            return
        }

        guard let element = effectiveBinding.element else {
            refuse(HostDomainError(.elementReleased))
            return
        }

        if promotedToWebContent, case .click = params.action {
            // WebKit can expose the renderer AX tree and actual pid a fraction
            // before its event bridge is ready. Pressing in that interval routes
            // through the host accessibility mirror and produces an untrusted
            // DOM click. This delay is paid only for mirror promotion.
            Thread.sleep(forTimeInterval: 0.2)
        }

        let settleMode = params.observeAfter?.settle ?? HostSettleMode.none
        let frontmostBefore = environment.frontmostApplicationPid()
        let windowIdsBefore = Set(
            environment.onScreenWindows()
                .filter { $0.pid == snapshot.pid }
                .map(\.windowId)
        )
        cancellations.markDispatched(id: id)
        let attempted = performElementAction(
            params.action,
            on: element,
            binding: effectiveBinding,
            window: window,
            settle: settleMode
        )
        var performed =
            attempted.outcome == .unknown
                && hostUnknownActionMayChangeWindowTopology(params.action)
                && windowTopologyChanged(
                    pid: snapshot.pid,
                    previousWindowIds: windowIdsBefore
                )
            ? confirmedWindowTopologyChange(attempted)
            : attempted
        if performed.outcome == .ok || performed.outcome == .unknown {
            restoreForegroundIfTargetTookIt(
               previousPid: frontmostBefore,
               targetPid: snapshot.pid
            )
        }

        if performed.outcome != .ok, let failure = performed.failure {
            // §4.1 — a refused dispatch does not spend its snapshot; the host may
            // fix the argument and retry against the same frame. `outcome_unknown`
            // does spend it, because we cannot prove the action did not land.
            if performed.outcome == .unknown {
                currentRegistry().spend(snapshot)
            }

            emit(
                id: id,
                toolCallId: params.toolCallId,
                dispatchFailure: failure,
                outcome: performed.outcome,
                tier: performed.tier,
                path: performed.path,
                verdict: performed.verdict
            )
            return
        }

        finishDispatch(
            id: id,
            toolCallId: params.toolCallId,
            snapshot: snapshot,
            outcome: performed.outcome,
            path: performed.path,
            verificationIsTreeDelta: performed.verdict.verification.method == .treeDelta,
            fallbackVerdict: performed.verdict,
            settleMode: settleMode,
            observeAfter: params.observeAfter,
            window: window
        )
    }

    private struct PerformedAction {
        let outcome: HostDispatchOutcome
        let path: HostDispatchPath
        let tier: HostDispatchTier
        let verdict: HostEffectVerdict
        let failure: HostDomainError?
    }

    private func performElementAction(
        _ action: HostElementAction,
        on element: AXUIElement,
        binding: HostElementBinding,
        window: HostWindowInfo,
        settle: HostSettleMode
    ) -> PerformedAction {
        switch action {
        case .click(.left, let count) where binding.dispatchPid != binding.pid:
            guard (1...2).contains(count),
                  let frame = binding.observed.frame?.cgRect
            else {
                return refused(.unsupportedAction)
            }
            let windowPoint = CGPoint(x: frame.midX, y: frame.midY)
            let screenPoint = CGPoint(
                x: window.bounds.minX + windowPoint.x,
                y: window.bounds.minY + windowPoint.y
            )
            do {
                try environment.postWebContentClick(
                    at: screenPoint,
                    windowPoint: windowPoint,
                    window: window,
                    dispatchPid: binding.dispatchPid,
                    count: count
                )
                return PerformedAction(
                    outcome: .ok,
                    path: .skylightPid,
                    tier: .coordinateBackground,
                    verdict: settle == .quiesce
                        ? HostEffectVerdict(
                            effect: .unverifiable,
                            verification: HostVerification(method: .treeDelta, observedChange: false)
                        )
                        : hostEffectNotChecked(),
                    failure: nil
                )
            } catch let error as HostDomainError {
                return failed(error.code, path: .skylightPid)
            } catch {
                return failed(.dispatchRefused, path: .skylightPid)
            }

        case .click(_, let count):
            guard let required = action.requiredElementAction else {
                // A middle click has no semantic equivalent: no AX action means
                // "the middle button". The host is told, rather than being given
                // a coordinate click it did not ask for.
                return refused(.elementNotActionable)
            }
            return performAXActionWithSyntheticFocus(
                required,
                on: element,
                binding: binding,
                window: window,
                repeatCount: count,
                settle: settle
            )

        case .secondaryAction(let name):
            // §6.5 — `secondary_action` gets `action_result` only. There is
            // nothing generic to read back.
            return performAXActionWithSyntheticFocus(
                name,
                on: element,
                binding: binding,
                window: window,
                repeatCount: 1,
                settle: .none
            )

        case .scroll(let direction, let pages):
            let name: HostElementActionName
            switch direction {
            case .up:
                name = .scrollUp
            case .down:
                name = .scrollDown
            case .left:
                name = .scrollLeft
            case .right:
                name = .scrollRight
            }

            if pages.rounded() == pages, binding.observed.actions.contains(name) {
                let semantic = performAXAction(
                    name,
                    on: element,
                    binding: binding,
                    repeatCount: Int(pages),
                    settle: settle
                )
                // `path: none` proves the OS refused before one page landed.
                // Only that side-effect-free arm may try the declared pid-bound
                // wheel path; partial or unknown AX delivery never falls through.
                if semantic.outcome != .failed || semantic.path != .none {
                    return semantic
                }
            }

            if pages.rounded() == pages,
               let pageButton = HostAX.pageScrollButton(in: element, direction: direction) {
                return performAXAction(
                    .press,
                    on: pageButton,
                    binding: binding,
                    repeatCount: Int(pages),
                    settle: settle,
                    requireAdvertisedAction: false
                )
            }

            guard let frame = binding.observed.frame?.cgRect else {
                return refused(.elementNotActionable)
            }
            let point = CGPoint(
                x: window.bounds.minX + frame.midX,
                y: window.bounds.minY + frame.midY
            )
            do {
                try environment.postPointEvent(
                    .scroll(direction: direction, pages: pages),
                    at: point,
                    from: nil,
                    pid: binding.dispatchPid,
                    path: .cgEventPid
                )
                return PerformedAction(
                    outcome: .ok,
                    path: .cgEventPid,
                    tier: .coordinateBackground,
                    verdict: settle == .quiesce
                        ? HostEffectVerdict(
                            effect: .unverifiable,
                            verification: HostVerification(method: .treeDelta, observedChange: false)
                        )
                        : hostEffectNotChecked(),
                    failure: nil
                )
            } catch let error as HostDomainError {
                return failed(error.code, path: .cgEventPid)
            } catch {
                return failed(.dispatchRefused, path: .cgEventPid)
            }

        case .setValue(let value):
            if binding.dispatchPid != binding.pid,
               hostIsWebContentTextRole(binding.observed.role) {
                return performWebContentTextReplacement(
                    value,
                    on: element,
                    binding: binding,
                    window: window
                )
            }

            guard HostAX.isSettable(element, kAXValueAttribute) else {
                return refused(.elementNotActionable)
            }

            guard let write = HostAX.preparedValueWrite(value, for: element) else {
                return refused(.elementNotActionable)
            }
            let previous = HostAX.stringLikeValue(element, kAXValueAttribute)
            if write.comparesNumerically,
               let previous,
               let currentNumber = Double(previous),
               let requestedNumber = Double(write.requestedReadback),
               currentNumber != requestedNumber {
                let direction: HostElementActionName =
                    requestedNumber > currentNumber ? .increment : .decrement
                let opposite: HostElementActionName =
                    direction == .increment ? .decrement : .increment
                if binding.observed.actions.contains(direction),
                   binding.observed.actions.contains(opposite) {
                    return performSteppedValueAction(
                        requested: write.requestedReadback,
                        previous: previous,
                        currentNumber: currentNumber,
                        requestedNumber: requestedNumber,
                        direction: direction,
                        opposite: opposite,
                        on: element
                    )
                }
            }

            let result = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                write.value
            )
            guard result == .success else {
                // A rejected write did not happen, and `path` is what the
                // dispatch did. `ax_attribute` here claimed a route was taken.
                return failed(.dispatchRefused, path: .none)
            }

            let readback = HostAX.stringLikeValue(element, kAXValueAttribute)
            return PerformedAction(
                outcome: .ok,
                path: .axAttribute,
                tier: .ax,
                verdict: hostEffectFromValueReadback(
                    requested: write.requestedReadback,
                    previous: previous,
                    readback: readback,
                    comparesNumerically: write.comparesNumerically
                ),
                failure: nil
            )

        case .selectText(let text):
            guard let value = HostAX.stringLikeValue(element, kAXValueAttribute),
                  let range = value.range(of: text)
            else {
                return refused(.elementNotActionable)
            }

            var cfRange = CFRange(
                location: value.distance(from: value.startIndex, to: range.lowerBound),
                length: text.count
            )
            guard let axRange = AXValueCreate(.cfRange, &cfRange) else {
                // Nothing was posted: the range could not even be expressed, so
                // this is "the executor cannot say this", not "the OS said no".
                return refused(.unsupportedAction)
            }

            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
            guard result == .success else {
                return failed(.dispatchRefused, path: .none)
            }

            return PerformedAction(
                outcome: .ok,
                path: .axAttribute,
                tier: .ax,
                verdict: hostEffectFromSelectionReadback(
                    requested: text,
                    readback: HostAX.selectedText(element)
                ),
                failure: nil
            )

        case .moveWindow, .resizeWindow, .minimizeWindow:
            return performWindowAction(action, on: element, binding: binding, window: window)
        }
    }

    private func performWebContentTextReplacement(
        _ requested: String,
        on element: AXUIElement,
        binding: HostElementBinding,
        window: HostWindowInfo
    ) -> PerformedAction {
        guard let previous = environment.elementStringValue(element) else {
            return refused(.elementNotActionable)
        }
        if previous == requested {
            return PerformedAction(
                outcome: .ok,
                path: .axAttribute,
                tier: .ax,
                verdict: hostEffectFromValueReadback(
                    requested: requested,
                    previous: previous,
                    readback: previous
                ),
                failure: nil
            )
        }

        let context = environment.beginSyntheticTargetFocus(
            pid: binding.pid,
            windowId: window.windowId
        )
        let result = performWebContentTextReplacementInPreparedWindow(
            requested,
            previous: previous,
            on: element,
            binding: binding
        )
        guard let context else {
            return result
        }
        guard environment.endSyntheticTargetFocus(context) else {
            return result.outcome == .refused || result.outcome == .failed
                ? result
                : unknownOutcome(path: result.path, tier: result.tier)
        }
        return result
    }

    private func performWebContentTextReplacementInPreparedWindow(
        _ requested: String,
        previous: String,
        on element: AXUIElement,
        binding: HostElementBinding
    ) -> PerformedAction {
        guard environment.setFocusedElement(element, pid: binding.pid) else {
            return refused(.focusChanged)
        }
        guard environment.elementIsFocused(element) else {
            return unknownOutcome(path: .axAttribute, tier: .ax)
        }
        if !previous.isEmpty, !environment.selectAllText(element) {
            return unknownOutcome(path: .axAttribute, tier: .ax)
        }

        do {
            if requested.isEmpty {
                try environment.postKeyEvent(
                    .key(name: "Backspace", modifiers: []),
                    pid: binding.dispatchPid
                )
            } else {
                try environment.postKeyEvent(
                    .type(requested),
                    pid: binding.dispatchPid
                )
            }
        } catch {
            return unknownOutcome(
                path: .cgEventPid,
                tier: .coordinateBackground
            )
        }

        var readback = environment.elementStringValue(element)
        for _ in 0..<5 where readback != requested {
            Thread.sleep(forTimeInterval: 0.05)
            readback = environment.elementStringValue(element)
        }
        return PerformedAction(
            outcome: .ok,
            path: .cgEventPid,
            tier: .coordinateBackground,
            verdict: hostEffectFromValueReadback(
                requested: requested,
                previous: previous,
                readback: readback
            ),
            failure: nil
        )
    }

    /// Numeric controls frequently accept an `AXValue` write without running
    /// their application action. When increment/decrement are available, use
    /// those actions so the control's business callback observes the change.
    ///
    /// One step is measured first. If the target is not an exact bounded number
    /// of those steps away, the probe step is reversed and the action fails
    /// rather than leaving a rounded value behind.
    private func performSteppedValueAction(
        requested: String,
        previous: String,
        currentNumber: Double,
        requestedNumber: Double,
        direction: HostElementActionName,
        opposite: HostElementActionName,
        on element: AXUIElement
    ) -> PerformedAction {
        guard AXUIElementPerformAction(element, direction.rawAXAction as CFString) == .success,
              let firstReadback = HostAX.stringLikeValue(element, kAXValueAttribute),
              let firstNumber = Double(firstReadback)
        else {
            return failed(.dispatchRefused, path: .axAction)
        }

        let step = firstNumber - currentNumber
        let remaining = (requestedNumber - firstNumber) / step
        let roundedRemaining = remaining.rounded()
        let reachesTarget =
            step.isFinite
            && step != 0
            && remaining.isFinite
            && remaining >= 0
            && abs(remaining - roundedRemaining) < 0.000_001
            && roundedRemaining <= 99

        guard reachesTarget else {
            let reversed = AXUIElementPerformAction(element, opposite.rawAXAction as CFString)
            let restored = HostAX.stringLikeValue(element, kAXValueAttribute)
            if reversed != .success || !hostNumericStringsEqual(restored, previous) {
                return unknownOutcome()
            }
            return failed(.dispatchRefused, path: .axAction)
        }

        for _ in 0..<Int(roundedRemaining) {
            guard AXUIElementPerformAction(element, direction.rawAXAction as CFString) == .success else {
                return unknownOutcome()
            }
        }

        let readback = HostAX.stringLikeValue(element, kAXValueAttribute)
        return PerformedAction(
            outcome: .ok,
            path: .axAction,
            tier: .ax,
            verdict: hostEffectFromValueReadback(
                requested: requested,
                previous: previous,
                readback: readback,
                comparesNumerically: true
            ),
            failure: nil
        )
    }

    private func hostNumericStringsEqual(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs, let left = Double(lhs), let right = Double(rhs) else {
            return false
        }
        return left.isFinite && right.isFinite && left == right
    }

    /// §6.1 — the three actions whose subject is the window itself.
    ///
    /// One body for all three because the shape is one shape: check that the
    /// target really is the window, check that the attribute is writable, read
    /// what is there, write, read it back, wait for the window server, and judge
    /// the action by the readback. Which attribute, and what a value looks like
    /// as a string, is the only thing that differs, and it is decided once in
    /// `hostWindowSubject(for:)`.
    private func performWindowAction(
        _ action: HostElementAction,
        on element: AXUIElement,
        binding: HostElementBinding,
        window: HostWindowInfo
    ) -> PerformedAction {
        // §5.3 — the snapshot's tree is rooted at the window, so `depth == 0` is
        // the window and nothing else is.
        //
        // Two reasons, and the second is the one that would break quietly. A
        // window's position is the one geometry this wire states in *screen*
        // points while every `element.frame` is window-local, so a non-root
        // target would leave the executor guessing which space the request was
        // in. And the wait below compares the *window's* frame, as the window
        // server reports it, against the *element's* own readback: for anything
        // but the window those are two different rectangles, so the wait could
        // never agree, and every such call would spend the whole ceiling before
        // answering with a verdict about one object and a wait about another.
        //
        // On this machine nothing else would get through anyway — `AXPosition`
        // and `AXSize` were not settable on any ordinary control sampled — so
        // this gate refuses nothing that would otherwise have worked. It is here
        // to make the contract true by construction rather than by that accident.
        guard binding.depth == 0 else {
            return refused(.elementNotActionable)
        }

        guard let subject = hostWindowSubject(for: action) else {
            return refused(.unsupportedAction)
        }

        // The honest refusal for Calculator, whose window advertises
        // `AXSize` and will not let anyone write it. Asking first is what makes
        // it `element_not_actionable` — an answer the model can act on — rather
        // than a write that comes back `kAXErrorFailure` and reads as a fault.
        guard HostAX.isSettable(element, subject.attribute) else {
            return refused(.elementNotActionable)
        }

        let previous = subject.read(element)
        guard subject.write(element) == .success else {
            return failed(.dispatchRefused, path: .none)
        }

        // What the application reports straight away. For a geometry write this
        // is already the new value, and it is what the window server has to catch
        // up to.
        let acknowledged = subject.read(element)

        // §6.1 — the application answers immediately and the window server finds
        // out afterwards (measured 26–172 ms). Everything downstream reads the
        // window server, so returning before it agrees would hand the host a
        // frame in which its own `observeAfter` cannot find the window.
        hostAwaitWindowServerAgreement(
            ceilingMs: hostWindowServerAgreementCeilingMs,
            pollMs: hostWindowServerPollMs,
            readback: acknowledged,
            subject: subject,
            sample: {
                environment.onScreenWindows()
                    .first { $0.pid == window.pid && $0.windowId == window.windowId }?
                    .bounds
            }
        )

        // The attribute is read again *after* the machine has caught up, and the
        // verdict is taken from that read rather than from the first one.
        //
        // Not all three attributes answer at the same speed, and the difference
        // is not cosmetic. `AXPosition` is the new value within 3–16 ms of the
        // write. `AXMinimized` is not: measured, it still read `false` on the
        // instant after a write that succeeded and the window did minimise, so
        // an executor judging on the first read answers `suspected_noop` for an
        // action that plainly happened — the exact false noop §6.5 spends its
        // length condemning, and it was reported by this file's live half before
        // this line existed.
        let readback = subject.read(element) ?? acknowledged

        // §6.5 — the same three arms `set_value` has, for the same reason: the
        // attribute written *is* the subject of the action. The third arm is
        // where the clamps land, and they are the ordinary case rather than the
        // exception — measured, a request for `(99999, 300)` came back
        // `(1687, -52)` and a request for 10 × 10 came back 115 × 46. Neither is
        // `confirmed`: the window is not where it was asked to be. Neither is
        // `suspected_noop`: it moved. Where it actually landed is a fact about
        // the window, and it is reported as one — in the post-observation's
        // `snapshot.target.bounds`.
        return PerformedAction(
            outcome: .ok,
            path: .axAttribute,
            tier: .ax,
            verdict: hostEffectFromValueReadback(
                requested: subject.requested,
                previous: previous,
                readback: readback
            ),
            failure: nil
        )
    }

    private func performAXAction(
        _ name: HostElementActionName,
        on element: AXUIElement,
        binding: HostElementBinding,
        repeatCount: Int,
        settle: HostSettleMode,
        requireAdvertisedAction: Bool = true
    ) -> PerformedAction {
        guard !requireAdvertisedAction || binding.observed.actions.contains(name) else {
            return refused(.elementNotActionable)
        }

        var delivered = 0
        for _ in 0..<max(repeatCount, 1) {
            let result = AXUIElementPerformAction(element, name.rawAXAction as CFString)
            switch result {
            case .success:
                delivered += 1
                continue
            case .invalidUIElement where delivered == 0:
                return refused(.elementReleased)
            case .cannotComplete, .invalidUIElement:
                // The app accepted neither the message nor a refusal, or a repeat
                // failed after an earlier one landed. Either way we cannot prove
                // the action did not land, and §4.1 spends the frame for exactly
                // this case.
                return unknownOutcome()
            default:
                // A failure part-way through a double or triple click means the
                // earlier presses did happen, so "nothing happened" would be a
                // lie; only a first-press failure is `failed`.
                //
                // `path: .none` on that first-press failure, because `path` is
                // what the dispatch *did* and a refused `AXUIElementPerformAction`
                // did nothing — §6.5's word for that is `none`. Reporting
                // `ax_action` said a route had been taken, and a host that reads
                // it that way spends the frame: measured across 30 real runs,
                // 15 refused `raise` calls each cost a second call answering
                // `reobserve_required` and a third spent re-observing a window
                // nothing had touched. That is 15-20% of every call made.
                return delivered == 0 ? failed(.dispatchRefused, path: .none) : unknownOutcome()
            }
        }

        // §6.5 — a bare `AXUIElementPerformAction` returning `.success` is not
        // confirmation. The tree delta, when settling was asked for, is.
        return PerformedAction(
            outcome: .ok,
            path: .axAction,
            tier: .ax,
            verdict: settle == .quiesce
                ? HostEffectVerdict(
                    effect: .unverifiable,
                    verification: HostVerification(method: .treeDelta, observedChange: false)
                )
                : hostEffectFromActionResult(),
            failure: nil
        )
    }

    private func performAXActionWithSyntheticFocus(
        _ name: HostElementActionName,
        on element: AXUIElement,
        binding: HostElementBinding,
        window: HostWindowInfo,
        repeatCount: Int,
        settle: HostSettleMode
    ) -> PerformedAction {
        let context = environment.beginSyntheticTargetFocus(
            pid: binding.pid,
            windowId: window.windowId
        )
        let result = performAXAction(
            name,
            on: element,
            binding: binding,
            repeatCount: repeatCount,
            settle: settle
        )
        guard let context else {
            return result
        }
        guard environment.endSyntheticTargetFocus(context) else {
            return result.outcome == .refused || result.outcome == .failed
                ? result
                : unknownOutcome(path: result.path, tier: result.tier)
        }
        return result
    }

    /// §6.5 — `refused` means nothing was dispatched, so it always reports
    /// `path: none`; the tier travels anyway, because it is the tier the executor
    /// would have used.
    private func refused(_ code: HostDomainErrorCode) -> PerformedAction {
        PerformedAction(
            outcome: .refused,
            path: .none,
            tier: .ax,
            verdict: hostEffectNotChecked(),
            failure: HostDomainError(code)
        )
    }

    /// §6.5 — `failed` means the path named here was attempted and the OS
    /// rejected it. Reporting that as `refused` erased the difference between
    /// "we never tried" and "we tried and it said no", which is the difference
    /// between "try something else" and "try again".
    private func failed(_ code: HostDomainErrorCode, path: HostDispatchPath) -> PerformedAction {
        PerformedAction(
            outcome: .failed,
            path: path,
            tier: path.tier ?? .ax,
            verdict: HostEffectVerdict(
                effect: .unverifiable,
                verification: HostVerification(method: .actionResult, observedChange: false)
            ),
            failure: HostDomainError(code)
        )
    }

    private func unknownOutcome(
        path: HostDispatchPath = .axAction,
        tier: HostDispatchTier = .ax
    ) -> PerformedAction {
        PerformedAction(
            outcome: .unknown,
            path: path,
            tier: tier,
            verdict: hostEffectFromActionResult(),
            failure: HostDomainError(.outcomeUnknown)
        )
    }

    private func confirmedWindowTopologyChange(
        _ attempted: PerformedAction
    ) -> PerformedAction {
        PerformedAction(
            outcome: .ok,
            path: attempted.path,
            tier: attempted.tier,
            verdict: HostEffectVerdict(
                effect: .confirmed,
                verification: HostVerification(method: .actionResult, observedChange: true)
            ),
            failure: nil
        )
    }

    private func windowTopologyChanged(
        pid: pid_t,
        previousWindowIds: Set<CGWindowID>
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var consecutiveChangedSamples = 0
        repeat {
            let currentWindowIds = Set(
                environment.onScreenWindows()
                    .filter { $0.pid == pid }
                    .map(\.windowId)
            )
            consecutiveChangedSamples =
                currentWindowIds == previousWindowIds
                ? 0
                : consecutiveChangedSamples + 1
            if consecutiveChangedSamples >= 2 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func restoreForegroundIfTargetTookIt(
        previousPid: pid_t?,
        targetPid: pid_t
    ) {
        guard let previousPid = hostForegroundPidToRestore(
            previousPid: previousPid,
            currentPid: environment.frontmostApplicationPid(),
            targetPid: targetPid
        ) else {
            return
        }
        _ = environment.restoreFrontmostApplication(pid: previousPid)
    }

    /// Common tail for all three dispatch methods: spend the frame the request
    /// quoted, settle, re-observe, and answer with one result carrying all four
    /// of `outcome`, `tier`, `path` and `effect`.
    func finishDispatch(
        id: Int,
        toolCallId: String,
        snapshot: HostSnapshot,
        outcome: HostDispatchOutcome,
        path: HostDispatchPath,
        verificationIsTreeDelta: Bool,
        fallbackVerdict: HostEffectVerdict,
        settleMode: HostSettleMode,
        observeAfter: HostObserveAfter?,
        window: HostWindowInfo
    ) {
        let digestBefore = snapshot.windowDigest
        currentRegistry().spend(snapshot)

        var settleReport = HostSettleReport(waitedMs: 0, quiesced: false, reason: .notRequested)
        var digestAfter: String?

        if settleMode == .quiesce {
            let settled = quiesce(snapshot: snapshot, window: window)
            settleReport = settled.report
            digestAfter = settled.digest
        }

        let verdict = verificationIsTreeDelta
            ? hostEffectFromTreeDelta(
                settle: settleMode,
                digestBefore: digestBefore,
                digestAfter: digestAfter,
                withoutDelta: fallbackVerdict
            )
            : fallbackVerdict

        var post: HostSnapshotPayload?
        var postError: HostDomainErrorPayload?

        if let observeAfter {
            switch buildSnapshot(
                session: snapshot.session,
                target: .window(pid: snapshot.pid, windowId: snapshot.windowId),
                includeImage: observeAfter.includeImage,
                menuScope: observeAfter.menu,
                maxElements: limits.maxElements,
                maxDepth: limits.maxDepth,
                maxTextChars: limits.maxTextChars
            ) {
            case .success(let fresh):
                currentRegistry().register(fresh)
                post = fresh.payload
            case .failure(let error):
                // §6.1 — the action happened and must be reported even though the
                // frame after it could not be.
                postError = HostDomainErrorPayload(error)
            }
        }

        emit(
            id: id,
            payload: HostDispatchResult(
                toolCallId: toolCallId,
                outcome: outcome,
                tier: path.tier ?? .ax,
                path: path,
                effect: verdict.effect,
                verification: verdict.verification,
                settle: settleReport,
                snapshot: post,
                postObservationError: postError
            )
        )
    }

    /// §6.1 — polls the AX tree without an image until two consecutive window
    /// digests match, or the budget can no longer pay for another look. The
    /// executor owns settling because it can watch the tree without a round trip.
    ///
    /// Everything about *when to stop* is in `hostSettle`, which is handed a
    /// clock; this only supplies the machine.
    private func quiesce(
        snapshot: HostSnapshot,
        window: HostWindowInfo
    ) -> (report: HostSettleReport, digest: String) {
        let probe = environment.bindingProbe(windowBounds: window.bounds)
        return hostSettle(
            ceilingMs: limits.settleCeilingMs,
            pollMs: hostSettlePollMs,
            sample: { hostRecomputeWindowDigest(snapshot: snapshot, window: window, probe: probe) }
        )
    }
}

// MARK: - Settling (§6.1)

/// Recomputes the window digest from the snapshot's own bindings, so the
/// comparison is over the same element set the host was shown.
///
/// A free function rather than a method because it is also what settling costs:
/// one call is one Accessibility round trip per recorded element, and the live
/// half of §12 vector 55 measures it against real windows without standing a
/// dispatch up to do so.
func hostRecomputeWindowDigest(
    snapshot: HostSnapshot,
    window: HostWindowInfo,
    probe: any HostElementBindingProbe
) -> String {
    let digests = snapshot.payload.elements.compactMap { observed -> String? in
        guard let binding = snapshot.binding(for: observed.token) else {
            return nil
        }
        guard let current = probe.currentDigestInput(binding) else {
            return nil
        }
        return hostElementDigest(current)
    }

    return hostWindowDigest(elementDigests: digests, bounds: window.bounds, title: window.title)
}

/// How long the executor waits between two looks at the same window. Not a
/// `limits` field: the host neither enforces it nor reasons about it, and §2's
/// rule is about bounds the host would otherwise hardcode.
let hostSettlePollMs = 50

/// §6.1 — the whole of "wait for this window to stop changing", with the machine
/// behind three closures.
///
/// `sample` returns the window digest as it is *now*. One call is a round trip
/// through Accessibility for every element the quoted snapshot recorded, and its
/// cost is set by the observed application, not by us: measured on macOS 26.5,
/// TextEdit's 13 elements recompute in 32–49 ms and Calculator's 65 in
/// 106–304 ms, while System Settings' 337 take 2.18–2.22 s and a Finder window's
/// 1114–1225 take 3.16–3.62 s. Two looks at that Finder window — the minimum
/// quiescence can be proven in — is over 6 s against a 2.5 s budget.
///
/// Three things this function is answering for, all of which the previous loop
/// got wrong:
///
/// 1. **`waitedMs` is measured, on every arm.** The old timeout arm reported
///    `limits.settleCeilingMs` as a constant, so a settle that really took 3.7 s
///    told the host 2500 — and `waitedMs` is the field the host traces
///    specifically to see overruns. A fabricated one does not merely lose a
///    measurement, it hides the two defects below from the only instrument
///    pointed at them.
///
/// 2. **The budget is checked before a look, not only after the wait.** The old
///    loop tested the clock at the top of the iteration, so a look beginning at
///    2499 ms ran to completion: the real ceiling was "the budget plus one whole
///    recomputation", and a recomputation is unbounded.
///
/// 3. **A window too expensive to look at twice says so.** Proving quiescence
///    needs two looks that agree, so a window whose single look costs more than
///    the budget has left can never be proven quiet — the old loop spent two
///    looks anyway and reported the timeout it was always going to report. This
///    one stops after the first look and says `window_too_slow`, which is a
///    different fact from `ceiling`: `ceiling` means it was compared and was
///    still moving, `window_too_slow` means it was never comparable here.
///
/// The first look is unconditional. There is no way to estimate what a window
/// costs without paying for one, and the digest it produces is what §6.5 judges
/// the dispatch by — an executor that skipped it to save time would report
/// `effect` from nothing at all. So the worst case is one look over budget,
/// where it used to be two.
///
/// The estimate is the costliest look so far rather than the last or the mean,
/// deliberately. Under-estimating starts a look that overruns the budget;
/// over-estimating ends the settle one look early and says so on the wire. Only
/// one of those two is honest.
func hostSettle(
    ceilingMs: Int,
    pollMs: Int,
    sample: () -> String,
    now: () -> Date = Date.init,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
) -> (report: HostSettleReport, digest: String) {
    let started = now()
    let budget = Double(ceilingMs) / 1000
    let poll = Double(pollMs) / 1000

    func waited() -> TimeInterval {
        now().timeIntervalSince(started)
    }

    // The one place `waitedMs` is produced, so no arm can answer it with
    // anything but the clock. Rounded rather than truncated: this is a duration
    // in milliseconds, and truncation would answer a 2.1499999 s wait — which is
    // what adding the same two intervals repeatedly produces in binary floating
    // point — with 2149.
    func report(_ reason: HostSettleReason, quiesced: Bool) -> HostSettleReport {
        HostSettleReport(waitedMs: Int((waited() * 1000).rounded()), quiesced: quiesced, reason: reason)
    }

    var previous: String?
    var costliestSample: TimeInterval = 0
    var samples = 0

    while true {
        let sampleStarted = waited()
        let current = sample()
        samples += 1
        costliestSample = max(costliestSample, waited() - sampleStarted)

        if current == previous {
            return (report(.quiesced, quiesced: true), current)
        }

        previous = current

        if budget - waited() < costliestSample + poll {
            // `samples` is the whole difference between the two answers: one
            // look means nothing was ever compared, two or more means the
            // comparison was made and the window had moved.
            return (report(samples > 1 ? .ceiling : .windowTooSlow, quiesced: false), current)
        }

        sleep(poll)
    }
}

// MARK: - Point, key, launch and capture

extension HostProtocolServer {
    func handleDispatchPoint(id: Int, params: HostDispatchPointParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        // §6.3 — `space` is required and single-valued. A required field with one
        // legal value is how a second space gets added later without either side
        // guessing which one it was handed.
        guard params.space == "image_px" else {
            emit(id: id, rpcError: HostRPCError.invalidParams("space"))
            return
        }

        // §6.5 — a point dispatch would have used a coordinate path, so that is
        // the tier a refusal reports even though nothing was dispatched.
        func refuse(_ error: HostDomainError) {
            emit(id: id, toolCallId: params.toolCallId, dispatchFailure: error, tier: .coordinateBackground)
        }

        let registry = currentRegistry()
        let snapshot: HostSnapshot
        switch registry.resolve(session: params.session, snapshotId: params.snapshotId, now: hostNowMs()) {
        case .success(let resolved):
            snapshot = resolved
        case .failure(let error):
            refuse(error)
            return
        }

        // The echo is host bookkeeping, not evidence about the world: a digest
        // that is not the one this snapshot recorded means the host paired a
        // window digest with the wrong `snapshotId`. Reporting `window_changed`
        // for it sent the host round the re-observe loop with the same wrong
        // pairing, which is the collapse §6.2 separates one level down.
        guard params.expectWindowDigest == snapshot.windowDigest else {
            refuse(HostDomainError(.elementDigestMismatch))
            return
        }

        if cancellations.isCancelledBeforeDispatch(id: id) {
            refuse(HostDomainError(.aborted))
            return
        }

        let windows = environment.onScreenWindows()
        guard let window = windows.first(where: { $0.pid == snapshot.pid && $0.windowId == snapshot.windowId }) else {
            refuse(HostDomainError(.windowGone))
            return
        }

        // §6.3 — a point has no element to anchor to, so the whole window is the
        // anchor, and an anchor is only an anchor if it is recomputed. Comparing
        // the echo against the recorded digest and stopping there checked the
        // host against itself: inside the TTL the click went to whatever the
        // window had become, and because the screen point is derived from the
        // *current* bounds a resize rescaled it silently.
        let probe = environment.bindingProbe(windowBounds: window.bounds)
        guard hostRecomputeWindowDigest(snapshot: snapshot, window: window, probe: probe) == snapshot.windowDigest else {
            refuse(HostDomainError(.windowChanged))
            return
        }

        // `image_px` is only meaningful against the image the quoted snapshot
        // carried, and its measured scale is the only conversion we trust.
        guard let scale = snapshot.payload.image?.scale, scale > 0 else {
            refuse(HostDomainError(.invalidPoint))
            return
        }

        let screenPoint = CGPoint(
            x: window.bounds.minX + params.point.x / scale,
            y: window.bounds.minY + params.point.y / scale
        )
        let screenStart = params.startPoint.map {
            CGPoint(
                x: window.bounds.minX + $0.x / scale,
                y: window.bounds.minY + $0.y / scale
            )
        }

        let path: HostDispatchPath
        switch hostPointDispatchPath(
            action: params.action,
            point: screenPoint,
            startPoint: screenStart,
            windowBounds: window.bounds,
            allowGlobalPointer: globalPointerAllowed()
        ) {
        case .success(let selected):
            path = selected
        case .failure(let error):
            refuse(error)
            return
        }

        let obscuring = windows
            .filter { $0.layer == 0 && $0.zIndex > window.zIndex && $0.windowId != window.windowId }
            .filter { !HostWindowInventory.isFullScreenDockSurface($0) }
            .map { (pid: $0.pid, rect: $0.bounds) }

        // §6.3 — the default is `any` here, not `same_app`. A pixel is a pixel:
        // anything on top of it owns it.
        if hostIsOccluded(
            policy: params.occlusionPolicy ?? .any,
            targetPid: snapshot.pid,
            targetPoint: screenPoint,
            obscuringWindows: obscuring
        ) {
            refuse(HostDomainError(.windowOccluded))
            return
        }

        let settleMode = params.observeAfter?.settle ?? HostSettleMode.none
        cancellations.markDispatched(id: id)

        do {
            try environment.postPointEvent(
                params.action,
                at: screenPoint,
                from: screenStart,
                pid: snapshot.pid,
                path: path
            )
        } catch let error as HostDomainError where error.code != .dispatchRefused {
            // The event was never built, so nothing was attempted.
            refuse(error)
            return
        } catch {
            // §6.5 — the path was taken and the OS rejected it: `failed`, naming
            // the path attempted, not `refused` with `path: none`.
            emit(
                id: id,
                toolCallId: params.toolCallId,
                dispatchFailure: HostDomainError(.dispatchRefused),
                outcome: .failed,
                tier: path.tier ?? .coordinateBackground,
                path: path,
                verdict: hostEffectFromActionResult()
            )
            return
        }

        finishDispatch(
            id: id,
            toolCallId: params.toolCallId,
            snapshot: snapshot,
            outcome: .ok,
            path: path,
            verificationIsTreeDelta: true,
            fallbackVerdict: hostEffectFromActionResult(),
            settleMode: settleMode,
            observeAfter: params.observeAfter,
            window: window
        )
    }

    // MARK: dispatch.key

    func handleDispatchKey(id: Int, params: HostDispatchKeyParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        // Keys are posted to the target pid, so a refusal names the coordinate
        // tier it would have used (§6.5).
        func refuse(_ error: HostDomainError) {
            emit(id: id, toolCallId: params.toolCallId, dispatchFailure: error, tier: .coordinateBackground)
        }

        let registry = currentRegistry()
        let snapshot: HostSnapshot
        switch registry.resolve(session: params.session, snapshotId: params.snapshotId, now: hostNowMs()) {
        case .success(let resolved):
            snapshot = resolved
        case .failure(let error):
            refuse(error)
            return
        }

        // §6.2 — the same three-way split as `dispatch.element`: an unminted
        // token is one fault, an echo the snapshot never recorded is another.
        guard let binding = snapshot.binding(for: params.focusToken) else {
            refuse(HostDomainError(.elementUnknown))
            return
        }

        guard binding.digest == params.expectElementDigest else {
            refuse(HostDomainError(.elementDigestMismatch))
            return
        }

        if cancellations.isCancelledBeforeDispatch(id: id) {
            refuse(HostDomainError(.aborted))
            return
        }

        let windows = environment.onScreenWindows()
        guard let window = windows.first(where: { $0.pid == snapshot.pid && $0.windowId == snapshot.windowId }) else {
            refuse(HostDomainError(.windowGone))
            return
        }

        if let failure = hostVerifyBinding(binding, probe: environment.bindingProbe(windowBounds: window.bounds)) {
            refuse(failure)
            return
        }

        // §6.4 — `focusToken` is required and verified. Typing into whatever
        // `focusedElement` has become since the snapshot is the same class of
        // defect as re-resolving an index.
        //
        // `focusPolicy: "acquire"` may move focus onto that element first, but
        // only here: after the token, the digest and the binding probe have all
        // agreed. Acquiring first would hand focus to an element the executor
        // has not yet established is still the one the snapshot described.
        guard let element = binding.element else {
            refuse(HostDomainError(.focusChanged))
            return
        }

        var focused = environment.focusedElement(pid: snapshot.pid)

        if (params.focusPolicy ?? .require) == .acquire,
           !(focused.map { CFEqual($0, element) } ?? false) {
            guard environment.setFocusedElement(element, pid: snapshot.pid) else {
                // No fallback: an element that refused focus is not an element to
                // post keys at and hope. §6.4 — the code is the same
                // `focus_changed` the strict path reports, because the observable
                // fact is the same one: focus is not where the request named.
                refuse(HostDomainError(.focusChanged))
                return
            }

            // The write's own success is not proof. Applications accept
            // `kAXFocused` and leave focus where it was, so the only evidence
            // accepted is a re-read.
            focused = environment.focusedElement(pid: snapshot.pid)
        }

        guard let focused, CFEqual(focused, element) else {
            refuse(HostDomainError(.focusChanged))
            return
        }

        // §6.5 — which observation may judge this action is decided by what the
        // action does, not by what is cheapest to read. The focused element's
        // value is read only when it is the thing the action changes; for a key
        // it is not, and reading it anyway is how every shortcut came back
        // `suspected_noop`.
        let evidence = hostKeyEvidence(for: params.action)
        let previousValue = evidence == .focusedElementValue
            ? HostAX.stringLikeValue(element, kAXValueAttribute)
            : nil
        let settleMode = params.observeAfter?.settle ?? HostSettleMode.none
        cancellations.markDispatched(id: id)

        do {
            try environment.postKeyEvent(params.action, pid: snapshot.pid)
        } catch {
            // §6.5 — the events were posted to the pid and rejected: `failed`,
            // naming the path that was attempted.
            emit(
                id: id,
                toolCallId: params.toolCallId,
                dispatchFailure: HostDomainError(.dispatchRefused),
                outcome: .failed,
                tier: .coordinateBackground,
                path: .cgEventPid,
                verdict: hostEffectFromActionResult()
            )
            return
        }

        let verdict: HostEffectVerdict
        switch evidence {
        case .focusedElementValue:
            let readback = HostAX.stringLikeValue(element, kAXValueAttribute)
            if previousValue == nil, readback == nil {
                // Nothing to read back means nothing was checked, and §6.5 makes
                // that distinguishable from "checked and inconclusive".
                verdict = hostEffectNotChecked()
            } else {
                verdict = HostEffectVerdict(
                    effect: readback == previousValue ? .suspectedNoop : .confirmed,
                    verification: HostVerification(method: .valueReadback, observedChange: readback != previousValue)
                )
            }

        case .windowDelta:
            // The verdict is decided in `finishDispatch`, after settling: this is
            // what is left when no settle was asked for and there is therefore no
            // delta to read. A key posted to a pid has no return value, so there
            // is no `action_result` to name here either — `method: "none"` is the
            // whole of what the executor can honestly say.
            verdict = hostEffectNotChecked()
        }

        finishDispatch(
            id: id,
            toolCallId: params.toolCallId,
            snapshot: snapshot,
            outcome: .ok,
            path: .cgEventPid,
            verificationIsTreeDelta: evidence == .windowDelta,
            fallbackVerdict: verdict,
            settleMode: settleMode,
            observeAfter: params.observeAfter,
            window: window
        )
    }

    // MARK: apps.launch

    func handleAppsLaunch(id: Int, params: HostAppsLaunchParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        let frontmostBefore = environment.frontmostApplicationPid()

        // §5.7 — the clock starts here, not after the app exists. The caller's
        // budget covers the whole of "make this app usable": a cold launch spends
        // most of it before there is a process to look for windows in, and an
        // executor that timed its own resolution against a hardcoded five seconds
        // refused a launch that had been given eight — while the app was starting
        // normally and did come up.
        let started = Date()
        let resolutionBudget = params.waitForWindowMs
            .flatMap { $0 > 0 ? TimeInterval($0) / 1000 : nil }
            ?? AppDiscovery.defaultLaunchWaitSeconds

        let app: HostRunningApp
        switch environment.launchApp(params.app, waitFor: resolutionBudget) {
        case .failure(let error):
            // §5.7 — `timeout` and `app_not_found` are different instructions to
            // the model. Reporting the app that is still starting as missing is
            // what sent it off to guess other names for an app that had launched.
            emit(id: id, failure: error)
            return
        case .success(let resolved):
            app = resolved
        }

        var windows: [HostAppsLaunchResult.LaunchedWindow] = []
        var reason = HostLaunchWaitReason.notRequested

        // §5 — the executor MUST wait for a window rather than returning the empty
        // array it sees at launch time. Measured: launch returns in 1.3–3.2 s and
        // the window is mapped 2.3–4.5 s in, so the array is empty on every real
        // launch unless somebody waits. What is left of the budget after
        // resolution is what the window gets.
        if let waitMs = params.waitForWindowMs, waitMs > 0 {
            reason = .timeout
            repeat {
                let found = environment.onScreenWindows()
                    .filter { $0.pid == app.pid && $0.layer == 0 }
                if !found.isEmpty {
                    windows = found.map {
                        HostAppsLaunchResult.LaunchedWindow(windowId: $0.windowId, title: $0.title)
                    }
                    reason = .windowAppeared
                    break
                }

                guard Date().timeIntervalSince(started) * 1000 < Double(waitMs) else {
                    break
                }

                Thread.sleep(forTimeInterval: 0.1)
            } while true
        } else {
            windows = environment.onScreenWindows()
                .filter { $0.pid == app.pid && $0.layer == 0 }
                .map { HostAppsLaunchResult.LaunchedWindow(windowId: $0.windowId, title: $0.title) }
        }

        let frontmostAfter = environment.frontmostApplicationPid()

        emit(
            id: id,
            payload: HostAppsLaunchResult(
                pid: app.pid,
                // §5.7 — the request may be a display name because a not-running
                // app has no `appId` yet; the answer is always in the one
                // namespace, and every later call uses it.
                appId: app.appId,
                name: app.name,
                // §5 — declared, not inferred. An absent boolean that means
                // "unknown" is a three-valued field pretending to be two, and a
                // launch that took the foreground is still reported as such.
                foregroundTaken: frontmostAfter == app.pid && frontmostBefore != app.pid,
                windows: windows,
                waited: HostAppsLaunchResult.Waited(
                    ms: Int(Date().timeIntervalSince(started) * 1000),
                    reason: reason
                )
            )
        )
    }

    // MARK: screen.capture

    func handleScreenCapture(id: Int, params: HostScreenCaptureParams) {
        guard requireSession(id: id, session: params.session) else {
            return
        }

        let displayId: CGDirectDisplayID
        if let requested = params.displayId {
            // §6.6 — a display the caller named and the machine does not have is
            // `-32602` on the field, never a capture that quietly happens
            // somewhere else. The default exists for a caller that declined to
            // choose, not for one that chose wrong: silently substituting the
            // main display would answer a question about display B with a
            // picture of display A, and the `displayId` in the result would
            // agree with the picture, so nothing downstream could notice.
            guard let parsed = UInt32(requested),
                  hostActiveDisplayIds().contains(CGDirectDisplayID(parsed))
            else {
                emit(id: id, rpcError: HostRPCError.invalidParams("displayId"))
                return
            }
            displayId = CGDirectDisplayID(parsed)
        } else {
            displayId = CGMainDisplayID()
        }

        switch HostCapture.captureDisplay(displayId: displayId) {
        case .failure(let error):
            emit(id: id, failure: error)
        case .success(let image):
            let logicalWidth = CGDisplayBounds(displayId).width
            switch currentImageStore().writePNG(image, namePrefix: "cap", logicalWidth: logicalWidth) {
            case .failure(let error):
                emit(id: id, failure: error)
            case .success(let reference):
                let capturedAt = hostNowMs()
                // §8 — this image is attached to no snapshot, so nothing else
                // would ever delete it. The session records it, expires it on the
                // snapshot TTL, and releases whatever is left at `session.end`.
                currentRegistry().registerUnattachedImage(
                    session: params.session,
                    path: reference.path,
                    capturedAt: capturedAt
                )
                currentRegistry().sweepUnattachedImages(now: capturedAt)

                emit(
                    id: id,
                    payload: HostScreenCaptureResult(
                        image: reference,
                        // The display actually captured, which is the requested
                        // one when there was one and the main display when there
                        // was not. The caller never has to infer which it got.
                        displayId: String(displayId),
                        capturedAt: capturedAt
                    )
                )
            }
        }
    }
}
