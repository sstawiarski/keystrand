import Foundation

extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `defaultValue` when it is missing or malformed (forward/backward compatible files).
    func value<T: Decodable>(_ key: Key, default defaultValue: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? defaultValue
    }

    /// Decodes an optional `key`, treating a malformed value like a missing one.
    func optionalValue<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// Decodes an array element by element, dropping elements that fail. `nil` when the key is missing or not an array.
    func lossyArray<T: Decodable>(_ key: Key) -> [T]? {
        guard let elements = try? decodeIfPresent([LossyElement<T>].self, forKey: key) else { return nil }
        return elements.compactMap(\.value)
    }

    /// Like `lossyArray`, plus how many elements were dropped (1 when the key holds something that is not an array).
    func lossyArrayCountingDropped<T: Decodable>(_ key: Key) -> (values: [T], dropped: Int) {
        guard contains(key) else { return ([], 0) }
        guard let elements = try? decode([LossyElement<T>].self, forKey: key) else { return ([], 1) }
        let values = elements.compactMap(\.value)
        return (values, elements.count - values.count)
    }
}

/// One array element that decodes to `nil` instead of failing the whole array.
struct LossyElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

enum DataFileBackup {
    /// Copies `url` to `<name>.<label>-<timestamp>.<ext>` in the same folder, so a later rewrite cannot lose data.
    @discardableResult
    static func preserve(_ url: URL, label: String) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        let backup = url.deletingLastPathComponent().appendingPathComponent("\(name).\(label)-\(stamp).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: backup.path) { return backup }
            try FileManager.default.copyItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }
}

/// A list file in the `{"schemaVersion": n, "items": [...]}` layout. A bare top-level array is the unversioned layout
/// and reads as version 1.
struct VersionedArrayFile<Element: Codable>: Codable {
    var schemaVersion: Int
    var items: [Element]
    /// Items that failed to decode and were left out of `items`.
    private(set) var droppedCount = 0

    init(items: [Element], schemaVersion: Int) {
        self.schemaVersion = schemaVersion
        self.items = items
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, default: 1)
        guard let elements = try c.decodeIfPresent([LossyElement<Element>].self, forKey: .items) else {
            throw DecodingError.keyNotFound(CodingKeys.items, .init(codingPath: [], debugDescription: "No items"))
        }
        items = elements.compactMap(\.value)
        droppedCount = elements.count - items.count
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, items
    }

    /// Loads decodable items; returns [] if the file is missing. Backs up the original beside it when the file is
    /// unreadable, drops items, or comes from a version newer than `currentVersion`.
    static func load(from url: URL, currentVersion: Int) -> [Element] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONFile.makeDecoder()
        guard let data = try? Data(contentsOf: url) else {
            DataFileBackup.preserve(url, label: "damaged")
            return []
        }
        if let file = try? decoder.decode(Self.self, from: data) {
            if file.schemaVersion > currentVersion {
                DataFileBackup.preserve(url, label: "v\(file.schemaVersion)")
            } else if file.droppedCount > 0 {
                DataFileBackup.preserve(url, label: "damaged")
            }

            return file.items
        }

        if let elements = try? decoder.decode([LossyElement<Element>].self, from: data) {
            let items = elements.compactMap(\.value)
            if items.count != elements.count { DataFileBackup.preserve(url, label: "damaged") }
            return items
        }

        DataFileBackup.preserve(url, label: "damaged")
        return []
    }
}
