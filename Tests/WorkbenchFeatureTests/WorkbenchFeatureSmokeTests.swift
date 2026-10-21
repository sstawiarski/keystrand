import Foundation
import WorkbenchFeature
import RedisCore
import SwiftUI
import TestSupport
import Testing

@MainActor
struct WorkbenchFeatureSmokeTests {
    @Test func publicViewsConstruct() {
        let session = RedisTestServer.mockSession()
        _ = session
        _ = WorkbenchView(session: session)
        _ = TutorialsPanelView(session: session)
    }
}
