import Foundation
import Observation
import RedisCore

@Observable
@MainActor
public final class ClusterDetailsViewModel {
    public let session: DatabaseSession
    let service: ClusterDetailsService

    public private(set) var details: ClusterDetails?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var lastRefresh: Date?
    /// Set after a failed fetch; auto refresh stays off until a manual refresh succeeds.
    public private(set) var isPollingStopped = false

    public init(session: DatabaseSession) {
        self.session = session
        self.service = ClusterDetailsService(session: session)
    }

    public static func shared(for session: DatabaseSession) -> ClusterDetailsViewModel {
        session.scopedObject(ClusterDetailsViewModel.self) { ClusterDetailsViewModel(session: session) }
    }

    public var isCluster: Bool { session.isCluster }

    /// Fetches once; overlapping calls are ignored so polling never stacks requests. Failures stay inline
    /// (`errorMessage`); polling stops until a manual refresh succeeds.
    public func refresh(manual: Bool = false) async {
        guard isCluster, !isLoading else { return }
        if !manual && isPollingStopped { return }
        isLoading = true
        defer { isLoading = false }
        do {
            details = try await service.fetch()
            errorMessage = nil
            isPollingStopped = false
            lastRefresh = Date()
        } catch {
            errorMessage = error.localizedDescription
            isPollingStopped = true
        }
    }

    /// Polling tick: skipped while the window is minimized, hidden or occluded.
    public func autoRefresh(isWindowVisible: Bool) async {
        guard isWindowVisible else { return }
        await refresh()
    }

    public var primaries: [ClusterNodeDetails] { details?.primaries ?? [] }

    public var primaryNodesHeader: String {
        let count = primaries.count
        return "\(count) Primary \(count == 1 ? "node" : "nodes")"
    }

    public var userText: String {
        guard let user = details?.user, !user.isEmpty else { return "Default" }
        return user
    }

    /// Index of the primary that holds the unique maximum for a metric.
    public func maxIndex<T: Comparable>(_ value: (ClusterNodeDetails) -> T) -> Int? {
        ClusterDetailsParser.uniqueMaxIndex(primaries.map(value))
    }
}
