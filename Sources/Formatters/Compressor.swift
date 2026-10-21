import Compression
import Foundation
import RESP

/// Per-database "automatic data decompression" setting.
public enum Compressor: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case none = "NONE"
    case gzip = "GZIP"
    case zstd = "ZSTD"
    case lz4 = "LZ4"
    case snappy = "SNAPPY"
    case brotli = "Brotli"
    case phpGZCompress = "PHPGZCompress"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "No decompression"
        case .gzip: return "GZIP"
        case .zstd: return "ZSTD"
        case .lz4: return "LZ4"
        case .snappy: return "SNAPPY"
        case .brotli: return "Brotli"
        case .phpGZCompress: return "PHP GZCompress"
        }
    }

    /// Leading bytes that identify the format, if any.
    public var magicBytes: [UInt8]? {
        switch self {
        case .gzip: return [0x1F, 0x8B]
        case .zstd: return ZSTD.magic
        case .lz4: return LZ4.frameMagic
        case .none, .snappy, .brotli, .phpGZCompress: return nil
        }
    }
}

public struct DecompressResult: Hashable, Sendable {
    /// Decompressed bytes, or the input when not compressed / not decodable.
    public var value: Data
    /// The compressor that succeeded, if any.
    public var compressor: Compressor?
    public var isCompressed: Bool
    /// Set when the value carries a compressor's magic bytes but could not be decoded.
    public var error: DecompressorError?

    public init(value: Data, compressor: Compressor? = nil, isCompressed: Bool = false, error: DecompressorError? = nil) {
        self.value = value
        self.compressor = compressor
        self.isCompressed = isCompressed
        self.error = error
    }
}

public enum DecompressorError: Error, LocalizedError, Sendable, Hashable {
    case unsupported(Compressor)
    case corrupt(Compressor, String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let c): return "Unsupported compression: \(c.displayName) data cannot be decoded."
        case .corrupt(let c, let detail): return "Invalid \(c.displayName) data: \(detail)"
        }
    }

    public var compressor: Compressor {
        switch self {
        case .unsupported(let c), .corrupt(let c, _): return c
        }
    }
}

/// GZIP / zlib / Brotli via the Compression framework; LZ4, Snappy, ZSTD hand-written.
public enum Decompressor {
    /// Decodes the configured compressor if its magic bytes match (GZIP, ZSTD, LZ4).
    /// For formats without magic (Snappy, Brotli, PHP GZCompress), keeps output only if decoding succeeds and changes the bytes.
    /// Returns other input unchanged.
    public static func decompress(_ data: Data, using compressor: Compressor) -> DecompressResult {
        guard compressor != .none, !data.isEmpty else { return DecompressResult(value: data) }
        let bytes = [UInt8](data)
        let byValue = magicCompressor(bytes)
        if let byValue, byValue != compressor { return DecompressResult(value: data) }

        if let magic = compressor.magicBytes, bytes.count > magic.count, bytes.starts(with: magic) {
            do {
                let out = try decode(bytes, as: compressor)
                return DecompressResult(value: Data(out), compressor: compressor, isCompressed: true)
            } catch {
                return DecompressResult(value: data, error: classify(error, compressor))
            }
        }

        guard let out = try? decode(bytes, as: compressor), out != bytes else { return DecompressResult(value: data) }
        if compressor == .lz4, !LZ4.isAppleFramed(bytes), out.count < bytes.count { return DecompressResult(value: data) }
        return DecompressResult(value: Data(out), compressor: compressor, isCompressed: true)
    }

    /// Detects the compressor from the value itself and decodes it ("auto" mode).
    public static func decompressAuto(_ data: Data) -> DecompressResult {
        guard let (compressor, inflated) = detection(data) else { return DecompressResult(value: data) }
        if let inflated { return DecompressResult(value: Data(inflated), compressor: compressor, isCompressed: true) }
        do {
            let out = try decode([UInt8](data), as: compressor)
            return DecompressResult(value: Data(out), compressor: compressor, isCompressed: true)
        } catch {
            return DecompressResult(value: data, error: classify(error, compressor))
        }
    }

    /// Strict decode: throws `DecompressorError` when the bytes are not valid for `compressor`.
    public static func decode(_ data: Data, as compressor: Compressor) throws -> Data {
        do {
            return Data(try decode([UInt8](data), as: compressor))
        } catch {
            throw classify(error, compressor)
        }
    }

    /// Compresses an edited value back with the same compressor before writing.
    public static func compress(_ data: Data, using compressor: Compressor) throws -> Data {
        let bytes = [UInt8](data)
        switch compressor {
        case .none: return data
        case .gzip: return Data(try wrap(compressor) { try DeflateContainers.gzip(bytes) })
        case .phpGZCompress: return Data(try wrap(compressor) { try DeflateContainers.deflateZlib(bytes) })
        case .zstd: return Data(ZSTD.encodeRaw(bytes))
        case .lz4: return Data(LZ4.encodeFrame(bytes))
        case .snappy: return Data(Snappy.encodeRaw(bytes))
        case .brotli:
            guard let out = try? AppleCompression.encode(bytes, algorithm: COMPRESSION_BROTLI) else {
                throw DecompressorError.unsupported(.brotli)
            }
            return Data(out)
        }
    }

    /// Guesses the compressor from magic bytes (`1f 8b` GZIP, `28 b5 2f fd` ZSTD, `04 22 4d 18` LZ4 frame,
    /// Apple `bv41` LZ4, framed Snappy) or a zlib header that decodes cleanly (PHP GZCompress).
    public static func detect(_ data: Data) -> Compressor? {
        detection(data)?.compressor
    }

    /// Returns detected compression and reuses bytes inflated to recognize zlib.
    static func detection(_ data: Data) -> (compressor: Compressor, inflated: [UInt8]?)? {
        let bytes = [UInt8](data.prefix(16))
        if let c = magicCompressor(bytes) { return (c, nil) }
        if data.count > 4, LZ4.isAppleFramed(bytes) { return (.lz4, nil) }
        if data.count > Snappy.streamIdentifier.count, bytes.starts(with: Snappy.streamIdentifier) { return (.snappy, nil) }
        if DeflateContainers.isZlibHeader(bytes), data.count > 6,
           let inflated = try? DeflateContainers.inflateZlib([UInt8](data)) {
            return (.phpGZCompress, inflated)
        }

        return nil
    }

    /// Compressors this build can decode.
    public static let supported: Set<Compressor> = [.gzip, .zstd, .lz4, .snappy, .brotli, .phpGZCompress]

    static func magicCompressor(_ bytes: [UInt8]) -> Compressor? {
        for c in [Compressor.gzip, .zstd, .lz4] {
            if let magic = c.magicBytes, bytes.count > magic.count, bytes.starts(with: magic) { return c }
        }

        return nil
    }

    static func decode(_ bytes: [UInt8], as compressor: Compressor) throws -> [UInt8] {
        switch compressor {
        case .none: return bytes
        case .gzip: return try DeflateContainers.gunzip(bytes)
        case .phpGZCompress: return try DeflateContainers.inflateZlib(bytes)
        case .zstd: return try ZSTD.decompress(bytes)
        case .lz4: return try LZ4.decompress(bytes)
        case .snappy: return try Snappy.decompress(bytes)
        case .brotli: return try AppleCompression.decode(bytes, algorithm: COMPRESSION_BROTLI).output
        }
    }

    private static func wrap<T>(_ compressor: Compressor, _ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw classify(error, compressor) }
    }

    static func classify(_ error: Error, _ compressor: Compressor) -> DecompressorError {
        if let e = error as? DecompressorError { return e }
        let text = String(describing: error)
        if text.contains("not supported") { return .unsupported(compressor) }
        return .corrupt(compressor, text.replacingOccurrences(of: "ZSTD: ", with: ""))
    }
}
