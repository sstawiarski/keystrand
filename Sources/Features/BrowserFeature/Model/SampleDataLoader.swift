import Foundation
import RedisCore

public enum SampleDataError: Error, LocalizedError, Sendable, Equatable {
    case missingResource(String)
    case commandsFailed(failed: Int, total: Int, firstError: String?)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Sample data file \"\(name)\" is missing from the app bundle."
        case .commandsFailed(let failed, let total, let firstError):
            let counts = "\(NumberFormatting.grouped(failed)) of \(NumberFormatting.grouped(total)) commands failed."
            guard let firstError else { return counts }
            return counts + " " + firstError
        }
    }
}

/// Bundled "Load sample data" commands: `common` always, plus files whose required modules are loaded.
public enum SampleDataLoader {
    struct Manifest: Decodable {
        struct File: Decodable {
            var path: String
            var modules: [String]?
        }

        var files: [File]
    }

    static var directory: URL? {
        Bundle.module.url(forResource: "SampleData", withExtension: nil)
    }

    /// Relative file names to run for `modules` (case-insensitive module names).
    public static func files(for modules: [RedisModuleInfo]) throws -> [String] {
        guard let directory else { throw SampleDataError.missingResource("SampleData") }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw SampleDataError.missingResource("manifest.json") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        return selectFiles(manifest, modules: modules)
    }

    static func selectFiles(_ manifest: Manifest, modules: [RedisModuleInfo]) -> [String] {
        let loaded = Set(modules.map { $0.name.lowercased() })
        return manifest.files.compactMap { file in
            guard let required = file.modules, !required.isEmpty else { return file.path }
            return required.contains { loaded.contains($0.lowercased()) } ? file.path : nil
        }
    }

    /// Concatenated command file (`\r\n` separated) for `modules`.
    public static func script(for modules: [RedisModuleInfo]) throws -> Data {
        guard let directory else { throw SampleDataError.missingResource("SampleData") }
        var out = Data()
        for (index, name) in try files(for: modules).enumerated() {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                throw SampleDataError.missingResource(name)
            }
            if index > 0 { out.append(contentsOf: Array("\r\n".utf8)) }
            out.append(data)
        }

        return out
    }
}
