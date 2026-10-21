import Foundation
import VectorSearchFeature
import RedisCore
import SwiftUI
import TestSupport
import Testing

@MainActor
struct VectorSearchFeatureSmokeTests {
    @Test func publicViewsConstruct() {
        let session = RedisTestServer.mockSession()
        _ = session
        _ = VectorSearchView(session: session)
    }
}
