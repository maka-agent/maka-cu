import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import XCTest
@testable import OpenComputerUseKit

/// The observation benchmark. It exists because every number this repository
/// has about `observe` cost came out of a trajectory that also contained a
/// model, and a model's own latency is larger than everything measured here put
/// together.
///
///     OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1 \
///         swift test --filter HostObservePerformanceLiveTests
///
/// Optional environment:
///
/// - `OPEN_COMPUTER_USE_BENCHMARK_APPS` — comma separated substrings matched
///   against the on-screen window list's app name, in order. Defaults to the
///   four windows the report is written against.
/// - `OPEN_COMPUTER_USE_BENCHMARK_RUNS` — samples per measurement, default 7.
///   Reported as a median; a single sample on a shared machine is noise.
///
/// It asserts nothing about wall-clock time. A timing assertion on a machine
/// with other work on it is a flake generator, and the point of this file is the
/// printed table, which is what a change gets compared against.
final class HostObservePerformanceLiveTests: XCTestCase {
    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    private var runs: Int {
        ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_BENCHMARK_RUNS"].flatMap(Int.init) ?? 7
    }

    private var appPatterns: [String] {
        if let raw = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_BENCHMARK_APPS"] {
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return ["计算器", "Calculator", "文本编辑", "TextEdit", "访达", "Finder", "系统设置", "System Settings"]
    }

    func testObservationCostBreakdown() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1 to run the observation benchmark")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required")
        }
        guard !hostScreenIsLocked() else {
            throw XCTSkip("A locked screen reports a menu bar and nothing else")
        }

        let windows = HostWindowInventory.onScreenWindows().filter { $0.layer == 0 }
        var seenPids = Set<pid_t>()
        var targets: [HostWindowInfo] = []
        for pattern in appPatterns {
            guard let match = windows.first(where: { $0.appName.contains(pattern) }) else {
                continue
            }
            guard seenPids.insert(match.pid).inserted else {
                continue
            }
            targets.append(match)
        }

        guard !targets.isEmpty else {
            throw XCTSkip("None of \(appPatterns) has an on-screen window")
        }

        print("")
        print("=== observation benchmark: \(runs) samples, medians in ms ===")
        print(
            pad("window", 22) + pad("shrCntnt", 10) + pad("shot", 9) + pad("cap:fresh", 12) + pad("cap:cached", 13)
                + pad("elements", 10) + pad("walk:1by1", 11) + pad("walk:batch", 11)
                + pad("ax:1by1", 9) + pad("ax:batch", 9) + pad("gain", 7)
        )

        for target in targets {
            benchmark(target: target)
        }

        microbenchmarkAttributeReads(target: targets[0])
    }

    private func benchmark(target: HostWindowInfo) {
        let shareable = median(runs) { () -> Double? in
            elapsedMs {
                _ = try? BlockingAsyncBridge.run(timeout: 10) {
                    _ = try await SCShareableContent.current
                    return 0
                }
            }
        }

        // Content and filter resolved outside the clock so the second column is
        // the compositor's cost for one image and nothing else.
        let filterBox = Box<SCContentFilter>()
        let windowId = target.windowId
        _ = try? BlockingAsyncBridge.run(timeout: 10) {
            let content = try await SCShareableContent.current
            if let window = content.windows.first(where: { $0.windowID == windowId }) {
                filterBox.value = SCContentFilter(desktopIndependentWindow: window)
            }
            return 0
        }

        var shot: Double?
        if let filter = filterBox.value {
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            configuration.scalesToFit = false
            configuration.ignoreShadowsSingleWindow = true
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
            configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))

            let inputs = Box<(SCContentFilter, SCStreamConfiguration)>()
            inputs.value = (filter, configuration)
            shot = median(runs) { () -> Double? in
                elapsedMs {
                    _ = try? BlockingAsyncBridge.run(timeout: 10) {
                        guard let (filter, configuration) = inputs.value else {
                            return CGImage?.none
                        }
                        return try await SCScreenshotManager.captureImage(
                            contentFilter: filter,
                            configuration: configuration
                        )
                    }
                }
            }
        }

        // Interleaved for the same reason the walks are. `invalidate()` is what
        // makes the first column the old behaviour: before the cache, every
        // capture fetched `SCShareableContent` and this is that, measured in the
        // same seconds as the capture that does not.
        var freshMs: [Double] = []
        var cachedMs: [Double] = []
        for _ in 0..<runs {
            HostShareableContentCache.invalidate()
            freshMs.append(elapsedMs {
                _ = HostCapture.captureWindow(windowId: target.windowId, scope: .window)
            })
            _ = HostCapture.captureWindow(windowId: target.windowId, scope: .window)
            cachedMs.append(elapsedMs {
                _ = HostCapture.captureWindow(windowId: target.windowId, scope: .window)
            })
        }
        let captureFresh = medianOf(freshMs)
        let captureCached = medianOf(cachedMs)

        guard
            let startTime = hostProcessStartTime(pid: target.pid),
            let element = HostAX.window(pid: target.pid, windowId: target.windowId, bounds: target.bounds)
        else {
            print(pad(label(target), 22) + "(no accessibility window)")
            return
        }

        var elementCount = 0
        var legacyCalls = 0
        var batchedCalls = 0
        var legacyMs: [Double] = []
        var batchedMs: [Double] = []

        // Interleaved rather than run in two blocks. This machine's load moves
        // over tens of seconds, and two blocks would attribute that movement to
        // the change under test.
        for _ in 0..<runs {
            let focused = HostAX.focusedElement(pid: target.pid)
            HostAXTelemetry.reset()
            legacyMs.append(elapsedMs {
                _ = hostWalkTree(
                    root: LegacyHostAXNode(
                        element: element,
                        windowBounds: target.bounds,
                        focusedElement: focused
                    ),
                    pid: target.pid,
                    processStartTime: startTime,
                    tokenPrefix: "bench",
                    bounds: HostTreeWalkBounds(maxElements: 1500, maxDepth: 64, maxTextChars: 400)
                )
            })
            legacyCalls = HostAXTelemetry.roundTrips

            var result: HostTreeWalkResult?
            HostAXTelemetry.reset()
            batchedMs.append(elapsedMs {
                result = hostWalkTree(
                    root: HostAXNode(
                        element: element,
                        windowBounds: target.bounds,
                        focusedElement: focused
                    ),
                    pid: target.pid,
                    processStartTime: startTime,
                    tokenPrefix: "bench",
                    bounds: HostTreeWalkBounds(maxElements: 1500, maxDepth: 64, maxTextChars: 400)
                )
            })
            batchedCalls = HostAXTelemetry.roundTrips
            elementCount = result?.elements.count ?? 0
        }

        let legacy = medianOf(legacyMs)
        let batched = medianOf(batchedMs)

        print(
            pad(label(target), 22)
                + pad(format(shareable), 10)
                + pad(format(shot), 9)
                + pad(format(captureFresh), 12)
                + pad(format(captureCached), 13)
                + pad(String(elementCount), 10)
                + pad(format(legacy), 11)
                + pad(format(batched), 11)
                + pad(String(legacyCalls), 9)
                + pad(String(batchedCalls), 9)
                + pad(batched > 0 ? String(format: "%.2fx", legacy / batched) : "-", 7)
        )
    }

    /// The whole of `observe`, through the protocol, which is the number the
    /// trajectory reported and the only one that answers "does a screenshot fit
    /// inside five seconds".
    ///
    /// It is a separate measurement from the columns above rather than their sum:
    /// §7.5 may rebuild the payload up to four times to fit `maxResponseBytes`,
    /// so a window whose tree is large pays for the walk more than once, and the
    /// menu walk of §5.8 is in here too.
    func testWholeObserveThroughTheProtocol() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_OBSERVE_BENCHMARK=1 to run the observation benchmark")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maka-cu-observe-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inbox = ResponseInbox()
        let server = HostProtocolServer(
            output: HostOutputWriter { inbox.append($0) },
            environment: HostLiveEnvironment()
        )
        server.handle(line: #"""
        {"jsonrpc":"2.0","id":1,"method":"host.hello","params":{"protocol":"\#(makaCuProtocolVersion)","hostPid":\#(ProcessInfo.processInfo.processIdentifier),"imageDir":"\#(directory.path)","allowGlobalPointer":false}}
        """#)
        _ = try inbox.next()
        server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"session.begin","params":{"session":"bench","captureScope":"window"}}"#)
        _ = try inbox.next()

        let windows = HostWindowInventory.onScreenWindows().filter { $0.layer == 0 }
        var targets: [HostWindowInfo] = []
        var seenPids = Set<pid_t>()
        for pattern in appPatterns {
            guard let match = windows.first(where: { $0.appName.contains(pattern) }), seenPids.insert(match.pid).inserted else {
                continue
            }
            targets.append(match)
        }

        print("")
        print("=== whole observe through the protocol, \(runs) samples, median ms ===")
        print(pad("window", 22) + pad("noImage", 11) + pad("withImage", 12) + pad("+menu:bar", 12) + pad("elements", 10))

        var identifier = 100
        func observe(_ window: HostWindowInfo, image: Bool, menu: Bool) throws -> (ms: Double, elements: Int) {
            identifier += 1
            let menuClause = menu ? #","menu":{"scope":"bar"}"# : ""
            let started = DispatchTime.now().uptimeNanoseconds
            server.handle(line: #"""
            {"jsonrpc":"2.0","id":\#(identifier),"method":"observe","params":{"session":"bench","target":{"kind":"window","appId":"\#(window.appId)","pid":\#(window.pid),"processGeneration":"\#(hostProcessGeneration(hostProcessStartTime(pid: window.pid) ?? 0))","windowId":\#(window.windowId)},"includeImage":\#(image)\#(menuClause)}}
            """#)
            let response = try inbox.next(timeout: 120)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let result = response["result"] as? [String: Any]
            let snapshot = result?["snapshot"] as? [String: Any]
            let elements = (snapshot?["elements"] as? [[String: Any]])?.count ?? -1
            return (ms, elements)
        }

        for window in targets {
            var noImage: [Double] = []
            var withImage: [Double] = []
            var withMenu: [Double] = []
            var elements = 0
            for _ in 0..<runs {
                let plain = try observe(window, image: false, menu: false)
                noImage.append(plain.ms)
                elements = plain.elements
                withImage.append(try observe(window, image: true, menu: false).ms)
                withMenu.append(try observe(window, image: true, menu: true).ms)
            }
            print(
                pad(label(window), 22)
                    + pad(format(medianOf(noImage)), 11)
                    + pad(format(medianOf(withImage)), 12)
                    + pad(format(medianOf(withMenu)), 12)
                    + pad(String(elements), 10)
            )
        }
    }

    /// Line-delimited responses collected off whichever lane produced them.
    private final class ResponseInbox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        private let arrived = DispatchSemaphore(value: 0)

        func append(_ data: Data) {
            lock.lock()
            lines.append(data)
            lock.unlock()
            arrived.signal()
        }

        func next(timeout: TimeInterval = 5) throws -> [String: Any] {
            guard arrived.wait(timeout: .now() + timeout) == .success else {
                throw ComputerUseError.message("no response within \(timeout)s")
            }

            lock.lock()
            let data = lines.removeFirst()
            lock.unlock()
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    /// One element, read the two ways the walk could read it. This is the number
    /// the per-element cost is made of, and it is measured apart from any tree so
    /// the tree's shape cannot be mistaken for the round trip's price.
    private func microbenchmarkAttributeReads(target: HostWindowInfo) {
        guard let element = HostAX.window(pid: target.pid, windowId: target.windowId, bounds: target.bounds) else {
            return
        }

        let names = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
            kAXDescriptionAttribute, kAXValueAttribute, "AXPlaceholderValue", kAXEnabledAttribute,
            kAXFocusedAttribute, kAXSelectedAttribute, kAXPositionAttribute, kAXSizeAttribute,
        ].map { $0 as String }

        let iterations = 200
        let single = elapsedMs {
            for _ in 0..<iterations {
                _ = HostAX.attribute(element, kAXRoleAttribute as String)
            }
        } / Double(iterations) * 1000

        let separate = elapsedMs {
            for _ in 0..<iterations {
                for name in names {
                    _ = HostAX.attribute(element, name)
                }
            }
        } / Double(iterations) * 1000

        let batched = elapsedMs {
            for _ in 0..<iterations {
                var values: CFArray?
                _ = AXUIElementCopyMultipleAttributeValues(
                    element,
                    names as CFArray,
                    AXCopyMultipleAttributeOptions(rawValue: 0),
                    &values
                )
            }
        } / Double(iterations) * 1000

        print("")
        print("=== attribute round trips against \(label(target)), \(iterations) iterations, µs ===")
        print(pad("one AXUIElementCopyAttributeValue", 46) + String(format: "%8.1f", single))
        print(pad("\(names.count) attributes, one call each", 46) + String(format: "%8.1f", separate))
        print(pad("\(names.count) attributes, CopyMultipleAttributeValues", 46) + String(format: "%8.1f", batched))
    }

    private func label(_ window: HostWindowInfo) -> String {
        String(window.appName.prefix(20))
    }

    private func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
    }

    private func format(_ value: Double?) -> String {
        guard let value else {
            return "-"
        }
        return String(format: "%.1f", value)
    }

    private func elapsedMs(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func median(_ count: Int, _ sample: () -> Double?) -> Double? {
        var values: [Double] = []
        for _ in 0..<count {
            if let value = sample() {
                values.append(value)
            }
        }
        return medianOf(values)
    }

    private func medianOf(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        return values.sorted()[values.count / 2]
    }
}
