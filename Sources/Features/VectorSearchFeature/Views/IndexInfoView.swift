import RedisUI
import SwiftUI

struct IndexAttributeRow: Identifiable {
    let id: Int
    let attribute: SearchIndexAttribute

    static func rows(_ info: SearchIndexInfo) -> [IndexAttributeRow] {
        info.attributes.enumerated().map { IndexAttributeRow(id: $0.offset, attribute: $0.element) }
    }
}

struct IndexInfoSummary: View {
    let info: SearchIndexInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(IndexListLogic.indexingSentence(info))
            Text(IndexListLogic.optionsText(filter: info.filter, language: info.defaultLanguage))
                .foregroundStyle(.secondary)
            Text(IndexListLogic.summaryText(info))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let state = IndexListLogic.stateText(info) {
                Text(state)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IndexAttributesTable: View {
    let info: SearchIndexInfo

    var body: some View {
        let flags = IndexListLogic.flagColumns(info.attributes)
        let showsWeight = IndexListLogic.hasWeights(info.attributes)
        Table(IndexAttributeRow.rows(info)) {
            TableColumn("Identifier") { row in MonospacedCell(row.attribute.identifier) }
                .width(min: 80, ideal: 140)
            TableColumn("Attribute") { row in MonospacedCell(row.attribute.attribute) }
                .width(min: 80, ideal: 120)
            TableColumn("Type") { row in Text(row.attribute.type.uppercased()) }
                .width(min: 60, ideal: 80)
            TableColumnForEach(showsWeight ? ["WEIGHT"] : [], id: \.self) { _ in
                TableColumn("Weight") { row in Text(row.attribute.weight ?? "").monospacedDigit() }
                    .width(min: 50, ideal: 60)
            }
            TableColumnForEach(flags, id: \.self) { flag in
                TableColumn(flag.capitalized) { row in
                    let isSet = row.attribute.flags.contains(flag)
                    Image(systemName: isSet ? "checkmark" : "xmark")
                        .foregroundStyle(isSet ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .accessibilityLabel(isSet ? "Yes" : "No")
                }
                .width(min: 50, ideal: 90)
                .alignment(.center)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

struct IndexInfoView: View {
    let info: SearchIndexInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IndexInfoSummary(info: info)
            IndexAttributesTable(info: info)
                .frame(height: min(CGFloat(info.attributes.count) * 24 + 32, 260))
        }
    }
}

struct IndexInfoSheet: View {
    let model: VectorSearchViewModel
    let indexName: Data
    let onDone: @MainActor () -> Void

    var body: some View {
        let title = TextTruncation.formatLongName(IndexListLogic.displayName(indexName), maxLength: 60, tail: 10)
        SheetForm(title: "Index “\(title)”", primaryTitle: "Done", cancelTitle: nil, onCancel: onDone,
                  onPrimary: onDone) {
            if let info = model.infos[indexName] {
                VStack(spacing: 12) {
                    IndexInfoSummary(info: info)
                        .padding(.horizontal, 20)
                    IndexAttributesTable(info: info)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: indexName) { await model.refreshInfo(indexName) }
    }
}

struct IndexInfoPane: View {
    let model: VectorSearchViewModel
    let indexName: Data

    var body: some View {
        Group {
            if let info = model.infos[indexName] {
                Form {
                    Section {
                        LabeledContent("Name") {
                            Text(IndexListLogic.displayName(indexName))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        if let keyType = info.keyType {
                            LabeledContent("Key Type", value: keyType == .hash ? "Hash" : "JSON")
                        }

                        LabeledContent("Prefixes") {
                            Text(info.prefixes.isEmpty ? "All keys" : IndexListLogic.prefixText(info.prefixes))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        if let filter = info.filter, !filter.isEmpty {
                            LabeledContent("Filter") { Text(filter).font(.body.monospaced()) }
                        }

                        if let language = info.defaultLanguage, !language.isEmpty {
                            LabeledContent("Language", value: language)
                        }
                    }
                    Section("Statistics") {
                        LabeledContent("Docs") { Text(NumberFormatting.grouped(info.numDocs)).monospacedDigit() }
                        LabeledContent("Records") { Text(NumberFormatting.grouped(info.numRecords)).monospacedDigit() }
                        LabeledContent("Terms") { Text(NumberFormatting.grouped(info.numTerms)).monospacedDigit() }
                        if let state = info.state {
                            LabeledContent("State", value: state)
                        }

                        if let backfill = IndexListLogic.backfillText(info) {
                            LabeledContent("Backfill") { Text(backfill).monospacedDigit() }
                        }
                    }
                    Section("Attributes") {
                        ForEach(IndexAttributeRow.rows(info)) { row in
                            LabeledContent {
                                Text(row.attribute.type.uppercased())
                            } label: {
                                Text(row.attribute.queryName)
                                    .font(.body.monospaced())
                                if !row.attribute.flags.isEmpty {
                                    Text(IndexListLogic.flagOrder.filter(row.attribute.flags.contains)
                                        .map(\.capitalized).joined(separator: ", "))
                                }
                            }
                            .help(row.attribute.identifier)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: indexName) { await model.refreshInfo(indexName) }
    }
}
