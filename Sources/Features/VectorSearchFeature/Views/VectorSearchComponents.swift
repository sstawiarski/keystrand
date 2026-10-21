import AppKit
import RedisUI
import SwiftUI

extension SearchIndexKeyType {
    var keyType: KeyType { self == .hash ? .hash : .json }
}

enum Pasteboard {
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
