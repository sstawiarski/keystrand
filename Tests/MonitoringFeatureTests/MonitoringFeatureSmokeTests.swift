import Foundation
import MonitoringFeature
import RedisCore
import SwiftUI
import TestSupport
import Testing

@MainActor
struct MonitoringFeatureSmokeTests {
    @Test func publicViewsConstruct() {
        let session = RedisTestServer.mockSession()
        _ = session
        _ = PubSubView(session: session)
        _ = ProfilerView(session: session)
    }
}
