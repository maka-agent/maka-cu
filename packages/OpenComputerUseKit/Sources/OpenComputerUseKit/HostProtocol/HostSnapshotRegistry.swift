import CoreGraphics
import Foundation
import Security

/// §4.1 — snapshot lifecycle. Five distinct failure codes, not one: `spent` and
/// `superseded` mean *re-observe and retry*, `evicted` means *the host is holding
/// too many frames*, and `unknown` after a restart means *the executor died*.
/// Collapsing them is how a retry loop becomes indistinguishable from a bug.

public enum HostSnapshotState: Equatable, Sendable {
    case live
    case spent
    case superseded
    case expired
    case evicted

    var domainErrorCode: HostDomainErrorCode? {
        switch self {
        case .live:
            return nil
        case .spent:
            return .snapshotSpent
        case .superseded:
            return .snapshotSuperseded
        case .expired:
            return .snapshotExpired
        case .evicted:
            return .snapshotEvicted
        }
    }
}

public final class HostSnapshot {
    public let id: String
    public let session: String
    public let pid: pid_t
    public let appId: String
    public let processGeneration: String
    public let windowId: CGWindowID
    public let capturedAt: Int64
    public let windowDigest: String
    public let payload: HostSnapshotPayload
    public let bindings: [String: HostElementBinding]
    let observationRevision: HostObservationRevision
    /// The image file this snapshot owns. §8 ties the file's lifetime to the
    /// snapshot's, so it is deleted the moment the snapshot leaves the live set.
    public let imagePath: String?
    public fileprivate(set) var state: HostSnapshotState = .live

    init(
        id: String,
        session: String,
        pid: pid_t,
        appId: String,
        processGeneration: String,
        windowId: CGWindowID,
        capturedAt: Int64,
        windowDigest: String,
        payload: HostSnapshotPayload,
        bindings: [HostElementBinding],
        imagePath: String?,
        observationRevision: HostObservationRevision? = nil
    ) {
        self.id = id
        self.session = session
        self.pid = pid
        self.appId = appId
        self.processGeneration = processGeneration
        self.windowId = windowId
        self.capturedAt = capturedAt
        self.windowDigest = windowDigest
        self.payload = payload
        self.bindings = Dictionary(uniqueKeysWithValues: bindings.map { ($0.token, $0) })
        self.imagePath = imagePath
        self.observationRevision = observationRevision
            ?? hostAssignRootStableIds(
                hostObservationRevision(from: payload.elements)
            )
    }

    /// §4.2 — exact string match in a per-snapshot dictionary. Never an index
    /// parsed back out of the token and re-resolved against a fresh tree.
    public func binding(for token: String) -> HostElementBinding? {
        bindings[token]
    }
}

public struct HostSessionReleaseCounts: Codable, Equatable, Sendable {
    public let snapshots: Int
    public let images: Int
    public let streams: Int
}

/// Owns every snapshot of every live session in this executor generation.
public final class HostSnapshotRegistry {
    /// §4.1 — a 128-bit per-process nonce, so an id minted by a previous
    /// generation fails `snapshot_unknown` instead of resolving against fresh
    /// state after a restart.
    public let processNonce: String
    private let limits: HostLimits
    private let deleteImage: (String) -> Void
    private var sessions: [String: HostSessionRecord] = [:]
    private var counter = 0
    private let lock = NSLock()

    private struct HostSessionRecord {
        let captureScope: HostCaptureScope
        var snapshots: [HostSnapshot] = []
        /// §8 — `screen.capture` images belong to no snapshot, so nothing here
        /// retires them. They are held with the time they were taken and expire
        /// on the same clock a snapshot's image does.
        var unattachedImages: [(path: String, capturedAt: Int64)] = []
    }

    public init(
        limits: HostLimits,
        processNonce: String = HostSnapshotRegistry.makeProcessNonce(),
        deleteImage: @escaping (String) -> Void = { path in
            try? FileManager.default.removeItem(atPath: path)
        }
    ) {
        self.limits = limits
        self.processNonce = processNonce
        self.deleteImage = deleteImage
    }

    public static func makeProcessNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Sessions

    public func beginSession(_ session: String, captureScope: HostCaptureScope) throws {
        lock.lock()
        defer { lock.unlock() }

        // §3 — reusing a live id is `-32602`, not an implicit reset. An accidental
        // reuse must not silently discard live snapshots.
        guard sessions[session] == nil else {
            throw HostRPCError.invalidParams("session")
        }

        sessions[session] = HostSessionRecord(captureScope: captureScope)
    }

    public func isSessionLive(_ session: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions[session] != nil
    }

    public func captureScope(of session: String) -> HostCaptureScope? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[session]?.captureScope
    }

    /// §3 — ending an unknown session is `ok: true` with zero counts, because
    /// teardown must be idempotent.
    @discardableResult
    public func endSession(_ session: String) -> HostSessionReleaseCounts {
        lock.lock()
        let record = sessions.removeValue(forKey: session)
        let snapshots = record?.snapshots ?? []
        let unattached = record?.unattachedImages ?? []
        lock.unlock()

        var images = 0
        for snapshot in snapshots where snapshot.state == .live {
            if let imagePath = snapshot.imagePath {
                deleteImage(imagePath)
                images += 1
            }
        }

        // §3 — teardown deletes every image file the session produced, which
        // includes the ones `screen.capture` wrote and never attached to
        // anything.
        for image in unattached {
            deleteImage(image.path)
            images += 1
        }

        return HostSessionReleaseCounts(
            snapshots: snapshots.filter { $0.state == .live }.count,
            images: images,
            streams: 0
        )
    }

    // MARK: Unattached images

    /// §8 — a `screen.capture` image has no snapshot to expire with, so the
    /// session records it and the sweep below deletes it once it is older than
    /// `limits.snapshotTtlMs`. Without this every capture leaked until the
    /// executor died, and only `imageDirBudgetBytes` stood between a long session
    /// and a full disk.
    public func registerUnattachedImage(session: String, path: String, capturedAt: Int64) {
        lock.lock()
        defer { lock.unlock() }
        sessions[session]?.unattachedImages.append((path: path, capturedAt: capturedAt))
    }

    @discardableResult
    public func sweepUnattachedImages(now: Int64) -> Int {
        lock.lock()
        var expired: [String] = []
        for (session, record) in sessions {
            var kept: [(path: String, capturedAt: Int64)] = []
            for image in record.unattachedImages {
                if now - image.capturedAt >= Int64(limits.snapshotTtlMs) {
                    expired.append(image.path)
                } else {
                    kept.append(image)
                }
            }
            sessions[session]?.unattachedImages = kept
        }
        lock.unlock()

        for path in expired {
            deleteImage(path)
        }

        return expired.count
    }

    // MARK: Snapshots

    public func nextSnapshotId() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return "snap_\(processNonce)_\(counter)"
    }

    /// Registers a freshly minted snapshot, superseding any live snapshot of the
    /// same `(pid, windowId)` and evicting the oldest when the session is over
    /// budget. §4.1: supersession is scoped to the window, so observing window B
    /// does not invalidate a live snapshot of window A.
    public func register(_ snapshot: HostSnapshot) {
        lock.lock()
        guard var record = sessions[snapshot.session] else {
            lock.unlock()
            return
        }

        var retired: [HostSnapshot] = []

        for existing in record.snapshots
        where existing.state == .live
            && existing.pid == snapshot.pid
            && existing.windowId == snapshot.windowId {
            existing.state = .superseded
            retired.append(existing)
        }

        record.snapshots.append(snapshot)

        var live = record.snapshots.filter { $0.state == .live }
        while live.count > limits.snapshotsPerSession {
            let oldest = live.removeFirst()
            oldest.state = .evicted
            retired.append(oldest)
        }

        sessions[snapshot.session] = record
        lock.unlock()

        for snapshot in retired {
            if let imagePath = snapshot.imagePath {
                deleteImage(imagePath)
            }
        }
    }

    /// Resolves a quoted snapshot, expiring it first if its TTL has run out.
    public func resolve(session: String, snapshotId: String, now: Int64) -> Result<HostSnapshot, HostDomainError> {
        lock.lock()
        guard let record = sessions[session],
              let snapshot = record.snapshots.first(where: { $0.id == snapshotId })
        else {
            lock.unlock()
            return .failure(HostDomainError(.snapshotUnknown))
        }

        if snapshot.state == .live, now - snapshot.capturedAt >= Int64(limits.snapshotTtlMs) {
            snapshot.state = .expired
            lock.unlock()
            if let imagePath = snapshot.imagePath {
                deleteImage(imagePath)
            }
            return .failure(HostDomainError(.snapshotExpired))
        }

        let state = snapshot.state
        lock.unlock()

        if let code = state.domainErrorCode {
            return .failure(HostDomainError(code))
        }

        return .success(snapshot)
    }

    func latestDifferenceBaseline(
        session: String,
        appId: String,
        pid: pid_t,
        processGeneration: String,
        windowId: CGWindowID
    ) -> HostSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[session]?.snapshots.last {
            $0.appId == appId
                && $0.pid == pid
                && $0.processGeneration == processGeneration
                && $0.windowId == windowId
                && $0.state != .expired
                && $0.state != .evicted
        }
    }

    /// §4.1 — a dispatch that returned `ok:true` with a mutating method, or
    /// `outcome_unknown`, spends the frame it quoted. A refused dispatch does not.
    public func spend(_ snapshot: HostSnapshot) {
        lock.lock()
        guard snapshot.state == .live else {
            lock.unlock()
            return
        }
        snapshot.state = .spent
        lock.unlock()

        if let imagePath = snapshot.imagePath {
            deleteImage(imagePath)
        }
    }

    public func liveSnapshotCount(session: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions[session]?.snapshots.filter { $0.state == .live }.count ?? 0
    }

    public func liveSessionIds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.keys)
    }

    public func snapshotState(session: String, snapshotId: String) -> HostSnapshotState? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[session]?.snapshots.first(where: { $0.id == snapshotId })?.state
    }
}
