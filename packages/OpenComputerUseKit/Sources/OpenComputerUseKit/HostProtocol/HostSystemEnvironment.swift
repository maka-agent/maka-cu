import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Everything the protocol handlers need to know about the live machine, behind
/// one seam.
///
/// It exists because the binding rules of §4 were unreachable from a test: every
/// dispatch handler read the window list, the permission state and the
/// Accessibility tree through file-scope statics, so deleting the digest
/// comparison, the binding probe or the occlusion gate left the whole suite
/// green. The live implementation below is the production path; the handlers name
/// nothing else.

/// §5.5 — one running application. `appId` is the §5.1 namespace; `name` is the
/// display string and is never matched against.
public struct HostRunningApp: Equatable, Sendable {
    public let appId: String
    public let pid: pid_t
    public let name: String
    public let running: Bool

    public init(appId: String, pid: pid_t, name: String, running: Bool) {
        self.appId = appId
        self.pid = pid
        self.name = name
        self.running = running
    }
}

public protocol HostSystemEnvironment {
    func screenIsLocked() -> Bool
    func permissions() -> PermissionDiagnostics
    func runningApps() -> [HostRunningApp]
    /// Bundle identifiers matching an installed application, without launching
    /// it or changing foreground state.
    func installedBundleIdentifiers(matching query: String) -> Result<[String], HostDomainError>
    /// Stable process birth identity used to bind an approved running target.
    func processStartTime(pid: pid_t) -> UInt64?
    /// The pid holding the foreground, or `nil` when nothing ordinary does.
    ///
    /// It is behind the seam because `apps.launch` reports `foregroundTaken` by
    /// comparing this across the launch, and a handler that reads the machine
    /// directly makes that field unassertable — which is how it went unnoticed
    /// that the field was answered from a value frozen at executor start.
    func frontmostApplicationPid() -> pid_t?
    /// Restore the application that held the foreground before a target-owned
    /// action activated itself. Never used to activate the target.
    func restoreFrontmostApplication(pid: pid_t) -> Bool
    /// Give a background target synthetic active state without changing the
    /// real frontmost application. Optional because the SPI may be unavailable.
    func beginSyntheticTargetFocus(
        pid: pid_t,
        windowId: CGWindowID
    ) -> SkyLightSyntheticFocusContext?
    func endSyntheticTargetFocus(_ context: SkyLightSyntheticFocusContext) -> Bool
    /// The unique WebKit WebContent process in the host app's coalition.
    func webContentProcess(pid: pid_t) -> pid_t?
    /// §5.7 — `apps.launch`. Resolves the request to a running application,
    /// starting it if it is not running yet, and gives up after `budget`.
    ///
    /// It is behind the seam for the reason the rest of this protocol is: the
    /// failure arms — nothing on disk, started but too slow, refused by the
    /// safety list — are otherwise only reachable by launching real
    /// applications on the machine running the tests.
    func launchApp(_ query: String, waitFor budget: TimeInterval) -> Result<HostRunningApp, HostDomainError>
    /// Front-to-back, as §5.4 requires.
    func onScreenWindows() -> [HostWindowInfo]
    func windowElement(pid: pid_t, windowId: CGWindowID, bounds: CGRect) -> AXUIElement?
    /// §5.8 — the application's menu bar as a walkable tree, or `nil` when the
    /// application has no menu bar at all.
    ///
    /// It hands back a node rather than an `AXUIElement`, unlike
    /// `windowElement(pid:windowId:bounds:)` above, for two reasons. The two
    /// decisions that make a menu node different from a window node — it reports
    /// no frame (§5.3), and it drops the Apple menu (§5.8) — belong on the side
    /// that knows it is looking at a menu, rather than being re-applied by every
    /// caller. And a seam that answers with an opaque Accessibility reference
    /// cannot be handed a tree by a test: a fake `AXUIElement` has no children,
    /// so every assertion about the shape of a menu observation would need a real
    /// application on the screen.
    func menuBarNode(pid: pid_t) -> HostAccessibilityNode?
    func focusedElement(pid: pid_t) -> AXUIElement?
    /// §6.4 — `focusPolicy: "acquire"`. Writes `kAXFocusedAttribute` and answers
    /// whether the write itself was accepted. It is not proof that focus moved:
    /// an application may return success and leave focus where it was, so the
    /// caller re-reads `focusedElement(pid:)` before posting anything.
    func setFocusedElement(_ element: AXUIElement, pid: pid_t) -> Bool
    func bindingProbe(windowBounds: CGRect) -> HostElementBindingProbe
    /// Posts an executor-derived, PID-bound event for an already bound semantic
    /// element action. Model-provided point dispatch never reaches this seam.
    func postPointEvent(
        _ action: HostPointAction,
        at point: CGPoint,
        from start: CGPoint?,
        pid: pid_t,
        path: HostDispatchPath
    ) throws
    /// A renderer-owned web element uses the host window for geometry/focus and
    /// the WebContent/renderer pid for final event delivery.
    func postWebContentClick(
        at screenPoint: CGPoint,
        windowPoint: CGPoint,
        window: HostWindowInfo,
        dispatchPid: pid_t,
        count: Int
    ) throws
    /// §6.4 — posted to the target pid. Behind the same seam as the pointer for
    /// the same reason: a handler that reaches the keyboard directly cannot be
    /// asserted against without typing into whatever process holds that pid.
    func postKeyEvent(_ action: HostKeyAction, pid: pid_t) throws
}

public struct HostLiveEnvironment: HostSystemEnvironment {
    public init() {}

    public func screenIsLocked() -> Bool {
        hostScreenIsLocked()
    }

    public func permissions() -> PermissionDiagnostics {
        PermissionDiagnostics.current()
    }

    public func runningApps() -> [HostRunningApp] {
        AppDiscovery.runningApps().map { app in
            HostRunningApp(
                appId: hostAppId(bundleIdentifier: app.bundleIdentifier, pid: app.pid),
                pid: app.pid,
                name: app.name,
                running: !app.runningApplication.isTerminated
            )
        }
    }

    public func installedBundleIdentifiers(
        matching query: String
    ) -> Result<[String], HostDomainError> {
        do {
            return .success(try AppDiscovery.matchingInstalledBundleIdentifiers(query))
        } catch {
            return .failure(hostAppLaunchFailure(error))
        }
    }

    public func processStartTime(pid: pid_t) -> UInt64? {
        hostProcessStartTime(pid: pid)
    }

    public func frontmostApplicationPid() -> pid_t? {
        LiveApplicationInventory.frontmostApplicationPid()
    }

    public func restoreFrontmostApplication(pid: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        return application.activate(options: [.activateAllWindows])
    }

    public func beginSyntheticTargetFocus(
        pid: pid_t,
        windowId: CGWindowID
    ) -> SkyLightSyntheticFocusContext? {
        try? SkyLightSPI.shared.beginSyntheticTargetFocus(
            targetPID: pid,
            targetWindowID: windowId
        )
    }

    public func endSyntheticTargetFocus(
        _ context: SkyLightSyntheticFocusContext
    ) -> Bool {
        do {
            try SkyLightSPI.shared.endSyntheticTargetFocus(context)
            return true
        } catch {
            return false
        }
    }

    public func webContentProcess(pid: pid_t) -> pid_t? {
        LiveApplicationInventory.uniqueWebContentProcess(for: pid)
    }

    public func launchApp(_ query: String, waitFor budget: TimeInterval) -> Result<HostRunningApp, HostDomainError> {
        do {
            let app = try AppDiscovery.resolve(query, waitFor: budget)
            return .success(
                HostRunningApp(
                    appId: hostAppId(bundleIdentifier: app.bundleIdentifier, pid: app.pid),
                    pid: app.pid,
                    name: app.name,
                    running: !app.runningApplication.isTerminated
                )
            )
        } catch {
            return .failure(hostAppLaunchFailure(error))
        }
    }

    public func onScreenWindows() -> [HostWindowInfo] {
        HostWindowInventory.onScreenWindows()
    }

    public func windowElement(pid: pid_t, windowId: CGWindowID, bounds: CGRect) -> AXUIElement? {
        HostAX.window(pid: pid, windowId: windowId, bounds: bounds)
    }

    public func menuBarNode(pid: pid_t) -> HostAccessibilityNode? {
        guard let element = HostAX.menuBar(pid: pid) else {
            return nil
        }

        return HostAXNode(
            element: element,
            // §5.3 — a menu has no window to be relative to, so it reports no
            // frame at all rather than a rectangle in a space this field does not
            // have. See `HostAXNode.windowBounds`.
            windowBounds: nil,
            // The snapshot has one focused element and it is the window's.
            focusedElement: nil,
            dropsAppleMenu: true
        )
    }

    public func focusedElement(pid: pid_t) -> AXUIElement? {
        HostAX.focusedElement(pid: pid)
    }

    public func setFocusedElement(_ element: AXUIElement, pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    public func bindingProbe(windowBounds: CGRect) -> HostElementBindingProbe {
        HostAXBindingProbe(windowBounds: windowBounds)
    }

    public func postPointEvent(
        _ action: HostPointAction,
        at point: CGPoint,
        from start: CGPoint?,
        pid: pid_t,
        path: HostDispatchPath
    ) throws {
        // Host element dispatch passes only PID-bound paths here. The retained
        // `dispatch.point` compatibility endpoint never calls this method.
        switch action {
        case .move:
            try InputSimulation.moveGlobally(to: point)
        case .leftClick(let count):
            try postClick(at: point, button: .left, count: count, pid: pid, path: path)
        case .rightClick(let count):
            try postClick(at: point, button: .right, count: count, pid: pid, path: path)
        case .middleClick(let count):
            try postClick(at: point, button: .middle, count: count, pid: pid, path: path)
        case .mouseDown, .mouseUp:
            // A half click has no target-bound form that survives the executor's
            // own event source going away between the two halves.
            throw HostDomainError(.unsupportedAction)
        case .drag:
            guard let start else {
                throw HostDomainError(.invalidPoint)
            }
            if path == .cgEventGlobal {
                try InputSimulation.dragGlobally(from: start, to: point)
            } else {
                try InputSimulation.dragTargeted(from: start, to: point, pid: pid)
            }
        case .scroll(let direction, let pages):
            if path == .cgEventGlobal {
                try InputSimulation.scrollGlobally(at: point, direction: direction.rawValue, pages: pages)
            } else {
                try InputSimulation.scrollTargeted(at: point, direction: direction.rawValue, pages: pages, pid: pid)
            }
        }
    }

    public func postKeyEvent(_ action: HostKeyAction, pid: pid_t) throws {
        // Key events are posted to the target pid. The executor never activates
        // the application, raises its window, or changes the frontmost app.
        switch action {
        case .type(let text):
            try InputSimulation.typeText(text, pid: pid)
        case .key(let name, let modifiers):
            // §6.4 — the decoder and this table read the same closed set
            // (`hostKeyNameIsSupported` is defined as "the table has a stroke"),
            // so `nil` is unreachable from the wire. It throws rather than
            // defaulting because a defaulted key press is an action the user did
            // not ask for and cannot see.
            guard let stroke = hostKeyStroke(name: name, modifiers: modifiers) else {
                throw HostDomainError(.unsupportedAction)
            }

            try InputSimulation.pressKeyStroke(stroke, pid: pid)
        }
    }

    public func postWebContentClick(
        at screenPoint: CGPoint,
        windowPoint: CGPoint,
        window: HostWindowInfo,
        dispatchPid: pid_t,
        count: Int
    ) throws {
        // `dispatchPid` was already generation-checked against the selected
        // WebContent element. WindowServer needs the host window owner here and
        // performs the final renderer hop itself.
        _ = dispatchPid
        try InputSimulation.clickWithSkyLight(
            at: screenPoint,
            windowPoint: windowPoint,
            windowBounds: window.bounds,
            windowID: window.windowId,
            clickCount: count,
            pid: window.pid,
            postsPublicEvent: false
        )
    }

    private func postClick(
        at point: CGPoint,
        button: MouseButtonKind,
        count: Int,
        pid: pid_t,
        path: HostDispatchPath
    ) throws {
        if path == .cgEventGlobal {
            try InputSimulation.clickGlobally(at: point, button: button, clickCount: count)
        } else {
            try InputSimulation.clickTargeted(at: point, button: button, clickCount: count, pid: pid)
        }
    }
}

// MARK: - Failing a launch (§5.7)

/// The ways `apps.launch` fails are different things, and the caller acts on
/// them differently. Collapsing them — which the handler used to do with a
/// `try?` that answered `app_not_found` to everything — told the model to try
/// another name in three cases where another name cannot help: the app was
/// still starting, the app is on the safety list, or the launch itself was
/// refused by the system.
public func hostAppLaunchFailure(_ error: Error) -> HostDomainError {
    guard let error = error as? ComputerUseError else {
        // `NSWorkspace.openApplication` said no. It was attempted and it did not
        // happen, which is what `dispatch_refused` means; the app is not missing.
        return HostDomainError(.dispatchRefused)
    }

    switch error {
    case .appNotFound:
        return HostDomainError(.appNotFound)
    case .timeout:
        return HostDomainError(.timeout)
    case .permissionDenied:
        // Not `permission_missing`: no macOS grant would change this answer. The
        // executor will not drive this application at all, so naming it again,
        // or granting something, is not the way forward.
        return HostDomainError(.unsupportedAction)
    case .message, .unsupportedTool, .invalidArguments, .stateUnavailable:
        return HostDomainError(.dispatchRefused)
    }
}

// MARK: - Resolving a running app identity

/// §5.1 / §5.2 — the executor resolves an `appId` by exact string match, against
/// applications that are **already running**, and refuses everything else.
///
/// Two rules are load-bearing and neither is defensive:
///
/// - No launch. `target.resolve` is a read. The previous implementation went through
///   `AppDiscovery.resolve`, which falls through to `NSWorkspace.openApplication`
///   with a configuration that activates, and then polls for five seconds — so
///   observing a not-running app started it and took the user's foreground, with
///   nothing on the wire saying so. `apps.launch` is the method that launches.
/// - No fallback to `appName` or `title`. Those are display strings (§1.2): they
///   are localised, two apps may share one, and matching them is how a caller's
///   `app` silently addressed a different process.
public func hostResolveAppTarget(
    appId: String,
    in apps: [HostRunningApp]
) -> Result<HostRunningApp, HostDomainError> {
    guard let match = apps.first(where: { $0.appId == appId }) else {
        return .failure(HostDomainError(.appNotFound))
    }

    return .success(match)
}
