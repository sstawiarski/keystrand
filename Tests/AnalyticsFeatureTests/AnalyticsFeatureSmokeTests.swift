import Foundation
import AnalyticsFeature
import RedisCore
import SwiftUI
import TestSupport
import Testing

@MainActor
struct AnalyticsFeatureSmokeTests {
    @Test func publicViewsConstruct() {
        let session = RedisTestServer.mockSession()
        _ = session
        _ = DatabaseAnalysisView(session: session)
        _ = SlowLogView(session: session)
        _ = ClusterDetailsView(session: session)
        _ = TipsPanelView(session: session)
    }
}
