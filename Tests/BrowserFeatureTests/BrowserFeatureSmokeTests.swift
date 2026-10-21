import Foundation
import BrowserFeature
import RedisCore
import SwiftUI
import TestSupport
import Testing

@MainActor
struct BrowserFeatureSmokeTests {
    @Test func publicViewsConstruct() {
        let session = RedisTestServer.mockSession()
        _ = session
        _ = BrowserView(session: session, keyDetails: { _ in AnyView(EmptyView()) })
    }
}
