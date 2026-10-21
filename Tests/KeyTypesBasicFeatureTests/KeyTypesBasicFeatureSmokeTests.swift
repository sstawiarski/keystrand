import Foundation
import KeyTypesBasicFeature
import RedisCore
import SwiftUI
import TestSupport
import Testing

@MainActor
struct KeyTypesBasicFeatureSmokeTests {
    @Test func publicViewsConstruct() {
        let session = RedisTestServer.mockSession()
        let context = KeyDetailsContext(session: session, key: Data("k".utf8), type: .string,
                                        state: KeyDetailsState(key: Data("k".utf8)))
        _ = session
        _ = KeyDetailsHeaderView(context: context)
        _ = StringKeyView(context: context)
        _ = HashKeyView(context: context)
        _ = ListKeyView(context: context)
        _ = SetKeyView(context: context)
    }
}
