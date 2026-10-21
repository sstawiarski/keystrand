import ConnectionsFeature
import RedisCore
import SwiftUI
import Testing

@MainActor
struct ConnectionsFeatureSmokeTests {
    @Test func publicViewsConstruct() {
        _ = HomeView(onOpenDatabase: { _ in }, autoDiscovery: nil)
        _ = HomeView(onOpenDatabase: { _ in }, onDatabasesDeleted: { _ in })
        _ = DatabaseFormView(mode: .add)
        _ = DatabaseFormView(mode: .edit(DatabaseConfig(name: "x")), focusEnvironment: true)
        _ = DatabaseFormView(mode: .clone(DatabaseConfig(name: "x")))
        _ = DatabasePickerPopover(currentDatabaseID: nil, onSelect: { _ in })
        _ = ManageTagsSheet(database: DatabaseConfig(name: "x"))
    }

    @Test func autoDiscoveryIsOffUnderTests() {
        #expect(LocalAutoDiscovery.appDefault == nil)
    }
}
