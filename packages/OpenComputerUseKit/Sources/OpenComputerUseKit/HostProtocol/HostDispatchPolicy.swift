import CoreGraphics
import Foundation

/// The decisions §6 takes away from the host: which path may carry an action,
/// which pairings are legal, when occlusion refuses, and what `effect` a piece of
/// evidence is allowed to claim. All of it is pure so it can be tested without a
/// desktop, and all of it is declared on the wire rather than inferred.

// MARK: - Requests

public enum HostElementAction: Equatable, Sendable {
    case click(button: HostMouseButton, count: Int)
    case setValue(String)
    case selectText(String)
    case secondaryAction(HostElementActionName)
    case scroll(direction: HostScrollDirection, pages: Double)
    /// §6.1 — screen logical points, the space `snapshot.target.bounds` and
    /// `displays[].logicalBounds` are already in. Not window-local: the window's
    /// own origin is what is being written.
    case moveWindow(HostPoint)
    case resizeWindow(HostSize)
    case minimizeWindow

    var requiredElementAction: HostElementActionName? {
        switch self {
        case .click(.left, _):
            return .press
        case .click(.right, _):
            return .showMenu
        case .click(.middle, _):
            return nil
        case .secondaryAction(let name):
            return name
        case .setValue, .selectText, .scroll:
            return nil
        case .moveWindow, .resizeWindow, .minimizeWindow:
            // Written as an attribute, not performed as an action. `AXRaise` is
            // the only action a window exposes — measured across seventeen
            // applications on this machine, every one of them advertised exactly
            // `["AXRaise"]` and nothing else — and it is already reachable as
            // `secondary_action`.
            return nil
        }
    }

    /// §6.1 — whether the subject of this action is the window rather than
    /// something drawn inside it.
    ///
    /// Two rules key off it and both are consequences of that one fact:
    ///
    /// - The target must be the snapshot root, because the window is the only
    ///   element whose geometry this wire states in screen points (§5.3).
    /// - Occlusion does not apply. The check asks whether the pixel about to be
    ///   acted on belongs to somebody else, and a window action acts on no pixel:
    ///   it moves the window and everything drawn in it, sheet included. A
    ///   covered window is precisely the window a model wants to move, and an
    ///   application started by `apps.launch` begins at the bottom of the z-order
    ///   — so applying occlusion here would refuse window management on every
    ///   freshly launched application, which is the defect §6.1 already had to
    ///   fix once for `same_app`.
    public var addressesTheWindowItself: Bool {
        switch self {
        case .moveWindow, .resizeWindow, .minimizeWindow:
            return true
        case .click, .setValue, .selectText, .secondaryAction, .scroll:
            return false
        }
    }
}

func hostUnknownActionMayChangeWindowTopology(_ action: HostElementAction) -> Bool {
    switch action {
    case .click(.left, 1), .secondaryAction(.press), .secondaryAction(.cancel):
        return true
    case .click, .setValue, .selectText, .secondaryAction, .scroll,
         .moveWindow, .resizeWindow, .minimizeWindow:
        return false
    }
}

func hostForegroundPidToRestore(
    previousPid: pid_t?,
    currentPid: pid_t?,
    targetPid: pid_t
) -> pid_t? {
    guard let previousPid,
          previousPid != targetPid,
          currentPid == targetPid
    else {
        return nil
    }
    return previousPid
}

public func hostIsWebContentTextRole(_ role: String) -> Bool {
    role == "AXTextField" || role == "AXTextArea"
}

public enum HostPointAction: Equatable, Sendable {
    case move
    case leftClick(count: Int)
    case rightClick(count: Int)
    case middleClick(count: Int)
    case mouseDown
    case mouseUp
    case drag
    case scroll(direction: HostScrollDirection, pages: Double)

    var needsStartPoint: Bool {
        self == .drag
    }
}

public enum HostKeyAction: Equatable, Sendable {
    case type(String)
    case key(name: String, modifiers: [HostKeyModifier])
}

// MARK: - Path selection

/// §6.3 — path selection is declared, not discovered. When `allowGlobalPointer`
/// is false and no permitted path can reach the target, the executor refuses; it
/// must never fall back. This is the invariant Maka refuses to trade: no cursor
/// warp, no z-order change.
public func hostPointDispatchPath(
    action: HostPointAction,
    point: CGPoint,
    startPoint: CGPoint?,
    windowBounds: CGRect,
    allowGlobalPointer: Bool
) -> Result<HostDispatchPath, HostDomainError> {
    // A pointer *move* has no pid-bound form: the only way to make the cursor
    // appear somewhere is to warp the system cursor, which is the one thing this
    // executor will not do on Maka's behalf.
    if action == .move {
        return allowGlobalPointer
            ? .success(.cgEventGlobal)
            : .failure(HostDomainError(.dispatchRefused, detail: .wouldRequirePath(.cgEventGlobal)))
    }

    guard windowBounds.contains(point) else {
        return .failure(HostDomainError(.invalidPoint))
    }

    if action.needsStartPoint {
        guard let startPoint else {
            return .failure(HostDomainError(.invalidPoint))
        }

        // A drag that begins outside the target window crosses a window boundary,
        // and only a global-tap drag is delivered to whichever window happens to
        // be under each intermediate point.
        guard windowBounds.contains(startPoint) else {
            return allowGlobalPointer
                ? .success(.cgEventGlobal)
                : .failure(HostDomainError(.dispatchRefused, detail: .wouldRequirePath(.cgEventGlobal)))
        }
    }

    return .success(.cgEventPid)
}

/// §6.3 — the host MUST reject an inconsistent `tier`/`path` pair as a protocol
/// violation rather than prefer one. The executor never emits one.
public func hostTierIsConsistent(tier: HostDispatchTier, path: HostDispatchPath) -> Bool {
    guard let expected = path.tier else {
        // `path: none` only ever accompanies a refusal, which reports the tier it
        // would have used; any tier is consistent with "nothing was dispatched".
        return true
    }

    return expected == tier
}

// MARK: - Occlusion

/// §6.2 — occlusion is a separate check from identity, with a separate code.
///
/// `same_app` is the default for element dispatch because a semantic dispatch
/// addresses an element, not a pixel: a foreign window stacked above it has no
/// bearing on whether `AXPress` reaches it. Treating foreign windows as occlusion
/// made background operation impossible in the case that matters most — an app
/// started by `apps.launch` begins at the bottom of the z-order, so every window
/// on the user's screen sat above it and every semantic click was refused.
public func hostIsOccluded(
    policy: HostOcclusionPolicy,
    targetPid: pid_t,
    targetPoint: CGPoint,
    obscuringWindows: [(pid: pid_t, rect: CGRect)]
) -> Bool {
    switch policy {
    case .none:
        return false
    case .any:
        return obscuringWindows.contains { $0.rect.contains(targetPoint) }
    case .sameApp:
        return obscuringWindows.contains { $0.pid == targetPid && $0.rect.contains(targetPoint) }
    }
}

// MARK: - Effect rules

public struct HostEffectVerdict: Equatable, Sendable {
    public let effect: HostDispatchEffect
    public let verification: HostVerification
}

/// §6.5 — a bare `AXUIElementPerformAction` returning `.success` is not
/// confirmation. It means the message was accepted, not that anything moved.
public func hostEffectFromActionResult() -> HostEffectVerdict {
    HostEffectVerdict(
        effect: .unverifiable,
        verification: HostVerification(method: .actionResult, observedChange: false)
    )
}

/// §6.5 — nothing was checked. The pairing matters as much as the effect:
/// `unverifiable` with a method named means *the executor looked and could not
/// tell*, and `unverifiable` with `method: "none"` means *the executor has no
/// observation that bears on this question at all*. A host cannot tell a driver
/// that does not verify from one that verified and could not confirm unless the
/// two are spelled differently.
public func hostEffectNotChecked() -> HostEffectVerdict {
    HostEffectVerdict(
        effect: .unverifiable,
        verification: HostVerification(method: .none, observedChange: false)
    )
}

/// §6.5 — which observation is entitled to judge a `dispatch.key` action.
///
/// The two `action.kind`s are not two spellings of one operation, and the
/// executor judged them as if they were.
///
/// `type` writes text into the element the request named and verified, so that
/// element's `AXValue` *is* the thing the action changes. Reading it back asks
/// the question the action was about, and a value that did not move is a real
/// `suspected_noop`.
///
/// A `key` is a command. The application decides what `cmd+p` means, and nothing
/// in this protocol says the answer turns up in the value of whatever held
/// focus: `cmd+p` opens a print sheet, `ctrl+f2` moves to the menu bar, `cmd+s`
/// writes a file, `cmd+w` closes the window, `Tab` moves focus off the element
/// entirely. None of them touch that value, so the readback answers "unchanged"
/// whether the key landed or not — and "unchanged" was being reported as
/// `suspected_noop`, which is the executor claiming to have checked.
///
/// Measured on a real run: a model asked to export a document found the menu bar
/// unreachable in the observation and reached for the shortcut, which is the
/// right move. `cmd+p` came back `ok … effect: suspected_noop` seven times and it
/// sent it seven times; a second model did the same with `ctrl+f2` four times.
/// The model's own account was that it must be getting the arguments wrong,
/// because the arguments were the only thing it could still see to change.
///
/// Whether those two keys landed is a separate question the executor never
/// answered, and separately measured (§14) they did not: both are main-menu key
/// equivalents, `performKeyEquivalent:` is reached through `NSApp`'s key window,
/// and a background application has none. That changes nothing here. The verdict
/// was not read off the key's effect; it was read off a value the key was never
/// going to touch, and the same reading condemns `cmd+A` on a text view of an
/// active application, which does land and leaves that value exactly where it was
/// — measured, in `HostKeyDispatchLiveTests`. A verdict that happens to correlate
/// with the truth for a reason unrelated to the truth is not evidence, and it
/// cost the model seven retries.
public enum HostKeyEvidence: Equatable, Sendable {
    /// The focused element's value, read either side of the post.
    case focusedElementValue
    /// The window digest across the settle — the same evidence a click is judged
    /// on, and with the same asymmetry: it can confirm, and it can never refute.
    case windowDelta
}

public func hostKeyEvidence(for action: HostKeyAction) -> HostKeyEvidence {
    switch action {
    case .type:
        return .focusedElementValue
    case .key:
        // Including a key with no modifiers. `Tab`, `Escape` and `Space` are as
        // far outside the focused element's value as `cmd+p` is; the modifier
        // list is not what makes a key a command.
        return .windowDelta
    }
}

/// §6.5 — `set_value` MUST read the value back. Equal to the requested value is
/// `confirmed`; equal to the *previous* value is `suspected_noop`; anything else
/// is `unverifiable`, because a third value means something else wrote it.
public func hostEffectFromValueReadback(
    requested: String,
    previous: String?,
    readback: String?,
    comparesNumerically: Bool = false
) -> HostEffectVerdict {
    guard let readback else {
        return HostEffectVerdict(
            effect: .unverifiable,
            verification: HostVerification(method: .valueReadback, observedChange: false)
        )
    }

    if hostValueReadbackEquals(readback, requested, comparesNumerically: comparesNumerically) {
        return HostEffectVerdict(
            effect: .confirmed,
            verification: HostVerification(
                method: .valueReadback,
                observedChange: previous.map {
                    !hostValueReadbackEquals(readback, $0, comparesNumerically: comparesNumerically)
                } ?? true
            )
        )
    }

    if previous.map({
        hostValueReadbackEquals(readback, $0, comparesNumerically: comparesNumerically)
    }) == true {
        return HostEffectVerdict(
            effect: .suspectedNoop,
            verification: HostVerification(method: .valueReadback, observedChange: false)
        )
    }

    return HostEffectVerdict(
        effect: .unverifiable,
        verification: HostVerification(method: .valueReadback, observedChange: true)
    )
}

private func hostValueReadbackEquals(
    _ lhs: String,
    _ rhs: String,
    comparesNumerically: Bool
) -> Bool {
    if lhs == rhs {
        return true
    }
    guard comparesNumerically,
          let left = Double(lhs),
          let right = Double(rhs),
          left.isFinite,
          right.isFinite
    else {
        return false
    }
    return left == right
}

public func hostEffectFromSelectionReadback(
    requested: String,
    readback: String?
) -> HostEffectVerdict {
    guard let readback else {
        return HostEffectVerdict(
            effect: .unverifiable,
            verification: HostVerification(method: .selectionReadback, observedChange: false)
        )
    }

    return HostEffectVerdict(
        effect: readback == requested ? .confirmed : .unverifiable,
        verification: HostVerification(method: .selectionReadback, observedChange: !readback.isEmpty)
    )
}

/// §6.5 — a click MAY report `confirmed` from a window-digest delta, but only
/// when `settle: "quiesce"` gave a change time to appear. With `settle: "none"`
/// no time was given, so absence of change is not evidence and neither is its
/// presence attributable to this action.
///
/// It never returns `suspected_noop`, and that is the point of it rather than an
/// omission: the digest is recomputed over the elements the quoted snapshot
/// recorded, so an effect that arrives as a new sheet, a new window, another
/// application or a file on disk leaves it byte-identical. Absence of a delta is
/// not absence of effect, and the executor is not entitled to say it is.
///
/// `withoutDelta` is what to report when no delta was taken, and it is required
/// rather than defaulted because it is a different sentence for every caller: an
/// `AXPress` that returned `.success` has an `action_result` to name, and a key
/// posted to a pid has nothing at all.
public func hostEffectFromTreeDelta(
    settle: HostSettleMode,
    digestBefore: String,
    digestAfter: String?,
    withoutDelta: HostEffectVerdict
) -> HostEffectVerdict {
    guard settle == .quiesce, let digestAfter else {
        return withoutDelta
    }

    let changed = digestAfter != digestBefore
    return HostEffectVerdict(
        effect: changed ? .confirmed : .unverifiable,
        verification: HostVerification(method: .treeDelta, observedChange: changed)
    )
}

// MARK: - Response budget

/// §7.5 — halve `maxElements` and retry up to three times, reporting the
/// reduction through `truncated.elements`. Never drop fields to fit.
public func hostFitResponse<Payload>(
    maxElements: Int,
    limitBytes: Int,
    build: (Int) throws -> (payload: Payload, encoded: Data)
) rethrows -> Result<(payload: Payload, encoded: Data), HostDomainError> {
    var elements = maxElements

    for attempt in 0...3 {
        let candidate = try build(elements)
        if candidate.encoded.count <= limitBytes {
            return .success(candidate)
        }

        if attempt == 3 {
            return .failure(
                HostDomainError(
                    .responseTooLarge,
                    detail: .responseSize(bytes: candidate.encoded.count, limit: limitBytes)
                )
            )
        }

        elements = max(1, elements / 2)
    }

    return .failure(HostDomainError(.responseTooLarge, detail: .responseSize(bytes: 0, limit: limitBytes)))
}
