import Compression
import Foundation

/// Uses `compression_stream` for raw DEFLATE (`COMPRESSION_ZLIB`) and Brotli.
enum AppleCompression {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Decodes a complete stream. Returns the output and how many input bytes the stream consumed.
    static func decode(_ input: [UInt8], algorithm: compression_algorithm, from start: Int = 0,
                       maxOutput: Int = 512 * 1024 * 1024) throws -> (output: [UInt8], consumed: Int) {
        try process(input, from: start, operation: COMPRESSION_STREAM_DECODE, algorithm: algorithm, maxOutput: maxOutput)
    }

    static func encode(_ input: [UInt8], algorithm: compression_algorithm) throws -> [UInt8] {
        try process(input, from: 0, operation: COMPRESSION_STREAM_ENCODE, algorithm: algorithm, maxOutput: Int.max).output
    }

    private static func process(_ input: [UInt8], from start: Int, operation: compression_stream_operation,
                                algorithm: compression_algorithm, maxOutput: Int) throws -> (output: [UInt8], consumed: Int) {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, operation, algorithm) == COMPRESSION_STATUS_OK else {
            throw Failure(description: "compression stream could not be initialised")
        }
        defer { compression_stream_destroy(streamPointer) }

        let chunk = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { destination.deallocate() }
        var output: [UInt8] = []
        let inputCount = input.count - start

        let source = input.isEmpty ? [UInt8(0)] : input
        return try source.withUnsafeBufferPointer { buffer -> (output: [UInt8], consumed: Int) in
            guard let base = buffer.baseAddress else { throw Failure(description: "empty input") }
            streamPointer.pointee.src_ptr = base.advanced(by: start)
            streamPointer.pointee.src_size = inputCount
            streamPointer.pointee.dst_ptr = destination
            streamPointer.pointee.dst_size = chunk
            while true {
                let status = compression_stream_process(streamPointer, Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - streamPointer.pointee.dst_size
                if produced > 0 {
                    output.append(contentsOf: UnsafeBufferPointer(start: destination, count: produced))
                    if output.count > maxOutput { throw Failure(description: "decompressed value is too large") }
                }

                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = chunk
                switch status {
                case COMPRESSION_STATUS_END:
                    return (output, inputCount - streamPointer.pointee.src_size)
                case COMPRESSION_STATUS_OK:
                    if produced == 0, streamPointer.pointee.src_size == 0 {
                        throw Failure(description: "unexpected end of compressed data")
                    }
                default:
                    throw Failure(description: "corrupt compressed data")
                }
            }
        }
    }
}

enum Checksum {
    private static let crc32Table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crc32Table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var a: UInt32 = 1, b: UInt32 = 0
        var n = 0
        for byte in bytes {
            a += UInt32(byte)
            b += a
            n += 1
            if n == 5552 {
                a %= 65521
                b %= 65521
                n = 0
            }
        }

        return (b % 65521) << 16 | (a % 65521)
    }

    /// xxHash32 (LZ4 frame header / content checksums).
    static func xxh32(_ input: [UInt8], seed: UInt32 = 0) -> UInt32 {
        let p1: UInt32 = 2_654_435_761, p2: UInt32 = 2_246_822_519, p3: UInt32 = 3_266_489_917
        let p4: UInt32 = 668_265_263, p5: UInt32 = 374_761_393
        func rotl(_ x: UInt32, _ r: UInt32) -> UInt32 { (x << r) | (x >> (32 - r)) }

        func read32(_ i: Int) -> UInt32 {
            UInt32(input[i]) | UInt32(input[i + 1]) << 8 | UInt32(input[i + 2]) << 16 | UInt32(input[i + 3]) << 24
        }

        func round(_ acc: UInt32, _ lane: UInt32) -> UInt32 { rotl(acc &+ lane &* p2, 13) &* p1 }
        var i = 0
        var h: UInt32
        if input.count >= 16 {
            var v1 = seed &+ p1 &+ p2, v2 = seed &+ p2, v3 = seed, v4 = seed &- p1
            while i + 16 <= input.count {
                v1 = round(v1, read32(i)); v2 = round(v2, read32(i + 4))
                v3 = round(v3, read32(i + 8)); v4 = round(v4, read32(i + 12))
                i += 16
            }

            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
        } else {
            h = seed &+ p5
        }

        h = h &+ UInt32(truncatingIfNeeded: input.count)
        while i + 4 <= input.count {
            h = rotl(h &+ read32(i) &* p3, 17) &* p4
            i += 4
        }

        while i < input.count {
            h = rotl(h &+ UInt32(input[i]) &* p5, 11) &* p1
            i += 1
        }

        h ^= h >> 15; h = h &* p2
        h ^= h >> 13; h = h &* p3
        h ^= h >> 16
        return h
    }
}

/// GZIP (RFC 1952) and zlib (RFC 1950) containers around raw DEFLATE.
enum DeflateContainers {
    /// Reads the single-member GZIP trailer from the last 8 bytes because Compression can read past the DEFLATE data.
    static func gunzip(_ input: [UInt8]) throws -> [UInt8] {
        var r = ByteReader(input)
        guard try r.u8() == 0x1F, try r.u8() == 0x8B else { throw ByteReaderError("missing GZIP header") }
        guard try r.u8() == 8 else { throw ByteReaderError("unknown GZIP compression method") }
        let flags = try r.u8()
        try r.skip(6)
        if flags & 0x04 != 0 { try r.skip(Int(try r.u16LE())) }
        if flags & 0x08 != 0 { while try r.u8() != 0 {} }
        if flags & 0x10 != 0 { while try r.u8() != 0 {} }
        if flags & 0x02 != 0 { try r.skip(2) }
        guard r.remaining >= 8 else { throw ByteReaderError.truncated }
        let body = Array(input[r.offset..<input.count - 8])
        let (output, _) = try AppleCompression.decode(body, algorithm: COMPRESSION_ZLIB)
        var trailer = ByteReader(input, offset: input.count - 8)
        let crc = try trailer.u32LE()
        let size = try trailer.u32LE()
        guard crc == Checksum.crc32(output) else { throw ByteReaderError("GZIP checksum mismatch") }
        guard size == UInt32(truncatingIfNeeded: output.count) else { throw ByteReaderError("GZIP size mismatch") }
        return output
    }

    static func gzip(_ input: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]
        out += try AppleCompression.encode(input, algorithm: COMPRESSION_ZLIB)
        out += littleEndian(Checksum.crc32(input))
        out += littleEndian(UInt32(truncatingIfNeeded: input.count))
        return out
    }

    static func isZlibHeader(_ input: [UInt8]) -> Bool {
        guard input.count > 2 else { return false }
        let cmf = input[0], flg = input[1]
        return cmf & 0x0F == 8 && cmf >> 4 <= 7 && (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0
    }

    static func inflateZlib(_ input: [UInt8]) throws -> [UInt8] {
        guard isZlibHeader(input), input.count >= 7 else { throw ByteReaderError("missing zlib header") }
        guard input[1] & 0x20 == 0 else { throw ByteReaderError("zlib preset dictionaries are not supported") }
        let (output, _) = try AppleCompression.decode(Array(input[2..<input.count - 4]), algorithm: COMPRESSION_ZLIB)
        var trailer = ByteReader(input, offset: input.count - 4)
        guard try trailer.u32BE() == Checksum.adler32(output) else { throw ByteReaderError("zlib checksum mismatch") }
        return output
    }

    static func deflateZlib(_ input: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9C]
        out += try AppleCompression.encode(input, algorithm: COMPRESSION_ZLIB)
        let adler = Checksum.adler32(input)
        out += [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
        return out
    }

    static func littleEndian(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
    }
}
