import KeyTypesAdvancedFeature
import KeyTypesBasicFeature
import RedisUI
import SwiftUI

/// Builds the Browser's key details pane from the key-type features (features never import each other).
@MainActor
enum KeyDetailsComposer {
    static func view(for context: KeyDetailsContext) -> AnyView {
        AnyView(
            VStack(spacing: 0) {
                KeyDetailsHeaderView(context: context)
                Divider()
                body(for: context)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        )
    }

    @ViewBuilder
    static func body(for context: KeyDetailsContext) -> some View {
        switch context.type {
        case .string: StringKeyView(context: context)
        case .hash: HashKeyView(context: context)
        case .list: ListKeyView(context: context)
        case .set: SetKeyView(context: context)
        case .zset: ZSetKeyView(context: context)
        case .stream: StreamKeyView(context: context)
        case .json: JSONKeyView(context: context)
        case .vectorSet: VectorSetKeyView(context: context)
        case .timeSeries: TimeSeriesKeyView(context: context)
        case .array: ArrayKeyView(context: context)
        case .graph, .unknown: UnsupportedKeyView(context: context)
        }
    }

    static func addKeyForm(type: KeyType, context: AddKeyFormContext) -> AnyView? {
        switch type {
        case .vectorSet: return AnyView(VectorSetAddKeyForm(context: context))
        default: return nil
        }
    }
}
