import SwiftUI

/// "Format" menu in `ValueFormat.menuOrder`, as wide as the current format's title. `compact` shows only the
/// `textformat` symbol.
public struct ValueFormatPicker: View {
    @Binding public var selection: ValueFormat
    public var compact: Bool

    public init(selection: Binding<ValueFormat>, compact: Bool = false) {
        self._selection = selection
        self.compact = compact
    }

    public var body: some View {
        Group {
            if compact {
                Menu {
                    picker.pickerStyle(.inline)
                } label: {
                    Label(selection.menuLabel, systemImage: "textformat")
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
            } else {
                HStack(spacing: 4) {
                    Text("Format").foregroundStyle(.secondary)
                    Menu {
                        picker.pickerStyle(.inline)
                    } label: {
                        Text(selection.menuLabel)
                    }
                    .menuStyle(.button)
                    .accessibilityLabel("Format")
                }
            }
        }
        .fixedSize()
        .help("Value format: \(selection.menuLabel)")
    }

    private var picker: some View {
        Picker("Format", selection: $selection) {
            ForEach(ValueFormat.menuOrder) { format in
                Text(format.menuLabel).tag(format)
            }
        }
    }
}
