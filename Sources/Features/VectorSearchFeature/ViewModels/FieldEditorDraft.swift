import Foundation
import RedisUI

/// Keeps numeric options as text so the field editor can validate partial input.
struct FieldEditorDraft: Identifiable, Hashable {
    enum Input: String, Hashable {
        case name, dimensions, maxEdges, maxNeighbors, candidateLimit, epsilon, weight, initialCap, blockSize, dataType
    }

    static let maxSampleDisplay = 500

    let id = UUID()
    var isNew: Bool
    var originalName: String?
    var name: String
    var sampleValue: String
    var type: SearchFieldType
    var algorithm: VectorAlgorithm
    var dataType: VectorDataType
    var distanceMetric: VectorDistanceMetric
    var dimensions: String
    var maxEdges: String
    var maxNeighbors: String
    var candidateLimit: String
    var epsilon: String
    var initialCap: String
    var blockSize: String
    var weight: String
    var phonetic: PhoneticMatcher

    init(field: IndexFieldDraft?) {
        let source = field ?? IndexFieldDraft(name: "", type: .text)
        isNew = field == nil
        originalName = field?.name
        name = source.name
        sampleValue = source.sampleValue
        type = source.type == .geoshape ? .text : source.type
        algorithm = source.vector.algorithm
        dataType = source.vector.dataType
        distanceMetric = source.vector.distanceMetric
        dimensions = source.vector.dimensions.map(String.init) ?? ""
        maxEdges = source.vector.maxEdges.map(String.init) ?? ""
        maxNeighbors = source.vector.maxNeighbors.map(String.init) ?? ""
        candidateLimit = source.vector.candidateLimit.map(String.init) ?? ""
        epsilon = source.vector.epsilon.map(FTCreateBuilder.formatNumber) ?? ""
        initialCap = source.vector.initialCap.map(String.init) ?? ""
        blockSize = source.vector.blockSize.map(String.init) ?? ""
        weight = source.text.weight.map(FTCreateBuilder.formatNumber) ?? ""
        phonetic = source.text.phonetic
    }

    var displaySample: String {
        sampleValue.count > Self.maxSampleDisplay ? String(sampleValue.prefix(Self.maxSampleDisplay)) + "…" : sampleValue
    }

    var sampleIsTruncated: Bool { sampleValue.count >= Self.maxSampleDisplay }

    // MARK: - Validation

    func errors(existingNames: Set<String>, supportsFloat16: Bool) -> [Input: String] {
        var errors: [Input: String] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if isNew {
            if trimmedName.isEmpty {
                errors[.name] = "Field name is required."
            } else if existingNames.contains(trimmedName) {
                errors[.name] = "A field with this name already exists."
            }
        }

        switch type {
        case .vector:
            let dims = dimensions.trimmingCharacters(in: .whitespaces)
            if dims.isEmpty {
                errors[.dimensions] = "Enter the number of dimensions."
            } else if !Self.int(dims, in: 1...32_768) {
                errors[.dimensions] = "Dimensions must be between 1 and 32768."
            }

            if dataType.requiresFloat16Support, !supportsFloat16 {
                errors[.dataType] = "\(dataType.rawValue) requires Redis Search 2.10 or later."
            }

            if !Self.optionalInt(initialCap, in: 1...Int(Int32.max)) {
                errors[.initialCap] = "Initial capacity must be a positive integer."
            }

            if algorithm == .flat, !Self.optionalInt(blockSize, in: 1...Int(Int32.max)) {
                errors[.blockSize] = "Block size must be a positive integer."
            }

            if algorithm == .hnsw {
                if !Self.optionalInt(maxEdges, in: 1...512) { errors[.maxEdges] = "Max edges must be between 1 and 512." }
                if !Self.optionalInt(maxNeighbors, in: 1...4096) {
                    errors[.maxNeighbors] = "Max neighbors must be between 1 and 4096."
                }

                if !Self.optionalInt(candidateLimit, in: 1...4096) {
                    errors[.candidateLimit] = "Candidate limit must be between 1 and 4096."
                }

                let eps = epsilon.trimmingCharacters(in: .whitespaces)
                if !eps.isEmpty, (Double(eps) ?? 0) <= 0 { errors[.epsilon] = "Epsilon must be greater than 0." }
            }
        case .text:
            let w = weight.trimmingCharacters(in: .whitespaces)
            if !w.isEmpty, (Double(w) ?? 0) <= 0 { errors[.weight] = "Weight must be greater than 0." }
        default:
            break
        }

        return errors
    }

    static func int(_ text: String, in range: ClosedRange<Int>) -> Bool {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { return false }
        return range.contains(value)
    }

    static func optionalInt(_ text: String, in range: ClosedRange<Int>) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || int(trimmed, in: range)
    }

    static func optionalInt(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces))
    }

    static func optionalDouble(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces))
    }

    func makeField() -> IndexFieldDraft {
        var field = IndexFieldDraft(name: isNew ? name.trimmingCharacters(in: .whitespaces) : (originalName ?? name),
                                    sampleValue: sampleValue, type: type)
        field.vector = VectorFieldOptions(algorithm: algorithm, dataType: dataType,
                                          dimensions: Self.optionalInt(dimensions), distanceMetric: distanceMetric,
                                          initialCap: Self.optionalInt(initialCap), blockSize: Self.optionalInt(blockSize),
                                          maxEdges: Self.optionalInt(maxEdges), maxNeighbors: Self.optionalInt(maxNeighbors),
                                          candidateLimit: Self.optionalInt(candidateLimit),
                                          epsilon: Self.optionalDouble(epsilon))
        field.text = TextFieldOptions(weight: Self.optionalDouble(weight), phonetic: phonetic)
        return field
    }
}
