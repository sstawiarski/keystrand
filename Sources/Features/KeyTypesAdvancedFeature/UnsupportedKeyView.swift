import RedisUI
import SwiftUI

/// Fallback for graph and unknown types: a module notice ("RedisGraph Key") or "Unsupported Key Type", with an action
/// that opens a suitable inspection command in Workbench.
public struct UnsupportedKeyView: View {
    public let context: KeyDetailsContext
    public var note: String?

    public init(context: KeyDetailsContext, note: String? = nil) {
        self.context = context
        self.note = note
    }

    public var body: some View {
        let notice = KeyTypeNotice(type: context.type, keyName: context.keyText)
        ContentUnavailableView {
            Label(notice.title, systemImage: notice.systemImage)
        } description: {
            Text(notice.description(note: note))
        } actions: {
            if notice.isModuleNotice || notice.workbenchScript != nil {
                Button("Open Workbench") {
                    context.session.navigator.navigate(.workbench(script: notice.workbenchScript))
                }
                .help(notice.workbenchScript ?? "Open Workbench")
            }
        }
    }
}

/// Texts and the suggested inspection command for a type without a dedicated view.
struct KeyTypeNotice: Equatable {
    let title: String
    let isModuleNotice: Bool
    let workbenchScript: String?

    init(type: KeyType, keyName: String) {
        let key = VectorSetCommands.quote(keyName)
        switch type {
        case .graph:
            title = "RedisGraph Key"
            isModuleNotice = true
            workbenchScript = "GRAPH.QUERY \(key) \"MATCH (n) RETURN n LIMIT 25\""
        case .timeSeries:
            title = "RedisTimeSeries Key"
            isModuleNotice = true
            workbenchScript = "TS.INFO \(key)"
        case .unknown(let raw):
            title = "Unsupported Key Type"
            isModuleNotice = false
            workbenchScript = Self.inspectCommand(forType: raw).map { "\($0) \(key)" }
        default:
            title = "Unsupported Key Type"
            isModuleNotice = false
            workbenchScript = nil
        }
    }

    var systemImage: String { isModuleNotice ? "puzzlepiece.extension" : "questionmark.square.dashed" }

    func description(note: String?) -> String {
        var text = isModuleNotice || workbenchScript != nil
            ? "Use Redis commands in Workbench to view the value."
            : "This key type is not currently supported."
        if !isModuleNotice, workbenchScript != nil { text = "This key type is not currently supported. " + text }
        if let note, !note.isEmpty { text += "\n\n" + note }
        return text
    }

    /// Info command for RedisBloom and other module types.
    static func inspectCommand(forType raw: String) -> String? {
        switch raw {
        case "MBbloom--", "bloomfltr": return "BF.INFO"
        case "MBbloomCF": return "CF.INFO"
        case "TopK-TYPE": return "TOPK.INFO"
        case "CMSk-TYPE": return "CMS.INFO"
        case "TDIS-TYPE": return "TDIGEST.INFO"
        default: return nil
        }
    }
}
