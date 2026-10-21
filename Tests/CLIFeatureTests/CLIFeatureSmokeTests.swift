import Foundation
import CLIFeature
import RedisCore
import SwiftUI
import TestSupport
import Testing

@MainActor
struct CLIFeatureSmokeTests {
    @Test func publicViewsConstruct() {
        let session = RedisTestServer.mockSession()
        _ = session
        _ = CLIView(session: session)
        _ = CommandHelperView(session: session)
    }
}
