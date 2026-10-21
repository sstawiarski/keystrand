import Foundation
import Observation
import RedisUI

@MainActor
@Observable
final class VectorSetAddKeyModel {
    let context: AddKeyFormContext

    var drafts: [VectorElementInput] = [VectorElementInput()]
    var quantization: VectorQuantization = .q8
    var reduceText = ""
    var efText = ""
    var linksText = ""
    var showsOptions = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    init(context: AddKeyFormContext) {
        self.context = context
    }

    /// The dimension comes from the earliest row holding a valid vector; later rows must match it.
    func expectedDimension(forDraftAt index: Int) -> Int? {
        for draft in drafts.prefix(index) {
            if case .success(let vector) = VectorParser.parse(draft.vector) { return vector.dimension }
        }

        return nil
    }

    var optionsError: String? {
        for (title, text) in [("Reduce dimension", reduceText), ("EF", efText), ("M", linksText)] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let value = Int(trimmed), value > 0 else { return "\(title) must be a positive whole number" }
        }

        if let reduce = Int(reduceText.trimmingCharacters(in: .whitespaces)),
           let dimension = drafts.lazy.compactMap({ try? VectorParser.parse($0.vector).get() }).first?.dimension,
           reduce >= dimension {
            return "Reduce dimension must be smaller than the vector dimension (\(dimension))"
        }

        return nil
    }

    var validationMessage: String? {
        if drafts.isEmpty { return "Add at least one element" }
        for (index, draft) in drafts.enumerated() {
            if draft.name.isEmpty { return "Enter an element name" }
            if case .failure(let error) = VectorParser.parse(draft.vector, expectedDimension: expectedDimension(forDraftAt: index)) {
                return error.localizedDescription
            }
        }

        return optionsError
    }

    var isValid: Bool { validationMessage == nil }

    var createOptions: VectorSetCreateOptions {
        VectorSetCreateOptions(quantization: quantization,
                               reduceDimension: Int(reduceText.trimmingCharacters(in: .whitespaces)),
                               buildEF: Int(efText.trimmingCharacters(in: .whitespaces)),
                               links: Int(linksText.trimmingCharacters(in: .whitespaces)))
    }

    func commands(for key: Data) -> [[RedisArgument]] {
        let options = createOptions
        return drafts.enumerated().compactMap { index, draft in
            guard case .success(let vector) = VectorParser.parse(draft.vector, expectedDimension: expectedDimension(forDraftAt: index)) else {
                return nil
            }
            let attributes = draft.attributes.trimmingCharacters(in: .whitespacesAndNewlines)
            return VectorSetCommands.add(key: key, element: Data(draft.name.utf8), vector: vector,
                                         attributes: attributes.isEmpty ? nil : attributes, create: options)
        }
    }

    var previewText: String {
        let key = context.keyName()
        guard let first = commands(for: key).first else { return "" }
        var binary: Set<Int> = []
        if let index = first.firstIndex(where: { $0.data == Data("FP32".utf8) }) { binary.insert(index + 1) }
        return VectorSetCommands.preview(first, binaryIndexes: binary)
    }

    /// Creates one element per `VADD` only if the key name is free, then applies any TTL.
    /// TTL failure reports an error but still counts the key as added.
    @discardableResult
    func submit() async -> Bool {
        let key = context.keyName()
        guard !key.isEmpty else {
            errorMessage = "Enter a key name."
            return false
        }
        guard isValid else {
            errorMessage = validationMessage
            return false
        }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        let session = context.session
        do {
            try await KeyOperations(session: session).createKey(key, commands: commands(for: key), ttl: context.ttl())
        } catch KeyOperationError.keyAlreadyExists {
            errorMessage = "This key name is already in use."
            return false
        } catch {
            guard case KeyOperationError.createdWithoutTTL = error else {
                errorMessage = error.localizedDescription
                return false
            }
            context.onKeyAdded(key)
            session.toasts.errorAfterSheetCloses(error, title: KeyOperationError.createdWithoutTTLTitle)
            return true
        }

        context.onKeyAdded(key)
        return true
    }
}
