import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Verifies the private AX-to-CGWindowID contract against real AppKit windows.
/// This test is opt-in because it requires a logged-in WindowServer session and
/// Accessibility access for the test runner.
@MainActor
final class HostWindowIdentityLiveTests: XCTestCase {
    func testProductionResolverMatchesAWindowAndAttachedSheet() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_WINDOW_ID_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_WINDOW_ID_LIVE_TEST=1 to run the live identity test")
        }
        XCTAssertTrue(hostWindowIdSPIAvailable(), "_AXUIElementGetWindow is required")

        let window = NSWindow(
            contentRect: CGRect(x: 240, y: 240, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Maka Window Identity Contract"
        window.makeKeyAndOrderFront(nil)

        let sheet = NSWindow(
            contentRect: CGRect(x: 300, y: 300, width: 360, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.beginSheet(sheet)
        defer {
            window.endSheet(sheet)
            sheet.orderOut(nil)
            window.orderOut(nil)
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        try assertResolved(windowNumber: window.windowNumber, expectedRole: kAXWindowRole as String)
        try assertResolved(windowNumber: sheet.windowNumber, expectedRole: "AXSheet")
    }

    private func assertResolved(windowNumber: Int, expectedRole: String) throws {
        let windowId = CGWindowID(windowNumber)
        let deadline = Date(timeIntervalSinceNow: 1)
        var info: HostWindowInfo?
        repeat {
            info = HostWindowInventory.onScreenWindows().first {
                $0.pid == getpid() && $0.windowId == windowId
            }
            if info == nil {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        } while info == nil && Date() < deadline

        let resolvedInfo = try XCTUnwrap(info, "WindowServer did not publish window \(windowId)")
        let element = try XCTUnwrap(
            HostAX.window(pid: getpid(), windowId: windowId, bounds: resolvedInfo.bounds),
            "Accessibility did not publish exact window \(windowId)"
        )
        XCTAssertEqual(hostWindowId(of: element), windowId)
        XCTAssertEqual(HostAX.string(element, kAXRoleAttribute), expectedRole)
    }
}
