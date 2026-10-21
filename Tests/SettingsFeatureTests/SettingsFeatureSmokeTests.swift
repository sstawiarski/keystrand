import Foundation
import SettingsFeature
import RedisCore
import SwiftUI
import TestSupport
import Testing

@MainActor
struct SettingsFeatureSmokeTests {
    @Test func publicViewsConstruct() {
        let session = RedisTestServer.mockSession()
        _ = SettingsView()
        _ = OverviewBarView(session: session)
        _ = DatabaseInfoPopover(session: session)
        _ = KeyboardShortcutsView()
    }
}
