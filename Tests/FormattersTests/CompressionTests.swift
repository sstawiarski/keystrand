import Compression
import Foundation
@testable import Formatters
import Testing

private func b64(_ s: String) -> Data { Data(base64Encoded: s) ?? Data() }

private struct Expected {
    let len: Int
    let crc: UInt32
}

private let expectations: [String: Expected] = [
    "short": Expected(len: Fixtures.short_len, crc: Fixtures.short_crc),
    "text": Expected(len: Fixtures.text_len, crc: Fixtures.text_crc),
    "mixed": Expected(len: Fixtures.mixed_len, crc: Fixtures.mixed_crc),
    "repeat": Expected(len: Fixtures.repeat_len, crc: Fixtures.repeat_crc),
]

private let fixtureSets: [(String, [Compressor: [String]])] = [
    ("short", [.gzip: [Fixtures.short_gzip], .phpGZCompress: [Fixtures.short_zlib],
               .zstd: [Fixtures.short_zstd1, Fixtures.short_zstd19],
               .lz4: [Fixtures.short_lz4, Fixtures.short_lz4linked, Fixtures.short_lz4legacy],
               .brotli: [Fixtures.short_brotli]]),
    ("text", [.gzip: [Fixtures.text_gzip], .phpGZCompress: [Fixtures.text_zlib],
              .zstd: [Fixtures.text_zstd1, Fixtures.text_zstd19],
              .lz4: [Fixtures.text_lz4, Fixtures.text_lz4linked, Fixtures.text_lz4legacy],
              .brotli: [Fixtures.text_brotli]]),
    ("mixed", [.gzip: [Fixtures.mixed_gzip], .phpGZCompress: [Fixtures.mixed_zlib],
               .zstd: [Fixtures.mixed_zstd1, Fixtures.mixed_zstd19],
               .lz4: [Fixtures.mixed_lz4, Fixtures.mixed_lz4linked, Fixtures.mixed_lz4legacy],
               .brotli: [Fixtures.mixed_brotli]]),
    ("repeat", [.gzip: [Fixtures.repeat_gzip], .phpGZCompress: [Fixtures.repeat_zlib],
                .zstd: [Fixtures.repeat_zstd1, Fixtures.repeat_zstd19],
                .lz4: [Fixtures.repeat_lz4, Fixtures.repeat_lz4linked, Fixtures.repeat_lz4legacy],
                .brotli: [Fixtures.repeat_brotli]]),
]

struct CompressionTests {
    @Test(arguments: fixtureSets.flatMap { name, map in
        map.flatMap { compressor, list in list.enumerated().map { "\(name)|\(compressor.rawValue)|\($0.offset)" } }
    })
    func decodesToolFixtures(_ id: String) throws {
        let parts = id.split(separator: "|").map(String.init)
        let name = parts[0]
        let compressor = try #require(Compressor(rawValue: parts[1]))
        let index = try #require(Int(parts[2]))
        let fixture = try #require(fixtureSets.first { $0.0 == name }?.1[compressor]?[index])
        let expected = try #require(expectations[name])
        let decoded = try Decompressor.decode(b64(fixture), as: compressor)
        #expect(decoded.count == expected.len)
        #expect(Checksum.crc32([UInt8](decoded)) == expected.crc)
    }

    @Test func detectsByMagicBytes() {
        #expect(Decompressor.detect(b64(Fixtures.text_gzip)) == .gzip)
        #expect(Decompressor.detect(b64(Fixtures.text_zstd1)) == .zstd)
        #expect(Decompressor.detect(b64(Fixtures.text_lz4)) == .lz4)
        #expect(Decompressor.detect(b64(Fixtures.text_zlib)) == .phpGZCompress)
        #expect(Decompressor.detect(Data("plain text value".utf8)) == nil)
        #expect(Decompressor.detect(Data("x^ looks like zlib".utf8)) == nil)
        #expect(Decompressor.detect(Data([0x1F, 0x8B])) == nil)
    }

    @Test func decompressRespectsConfiguredCompressor() {
        let gz = b64(Fixtures.short_gzip)
        let ok = Decompressor.decompress(gz, using: .gzip)
        #expect(ok.isCompressed)
        #expect(ok.compressor == .gzip)
        #expect(String(decoding: ok.value, as: UTF8.self) == "Hello, Redis!")

        let mismatch = Decompressor.decompress(gz, using: .zstd)
        #expect(!mismatch.isCompressed)
        #expect(mismatch.value == gz)

        let none = Decompressor.decompress(gz, using: .none)
        #expect(!none.isCompressed)
        #expect(none.value == gz)

        let plain = Data("not compressed".utf8)
        for c in Compressor.allCases {
            let r = Decompressor.decompress(plain, using: c)
            #expect(r.value == plain, "\(c)")
            #expect(!r.isCompressed, "\(c)")
        }
    }

    @Test func corruptMagicValueReportsError() {
        var bytes = [UInt8](b64(Fixtures.text_gzip))
        bytes[bytes.count / 2] ^= 0xFF
        let r = Decompressor.decompress(Data(bytes), using: .gzip)
        #expect(!r.isCompressed)
        #expect(r.value == Data(bytes))
        #expect(r.error != nil)

        let truncated = b64(Fixtures.text_zstd19).prefix(40)
        let z = Decompressor.decompress(Data(truncated), using: .zstd)
        #expect(!z.isCompressed)
        if case .corrupt(.zstd, _)? = z.error {} else { Issue.record("expected corrupt zstd error, got \(String(describing: z.error))") }
    }

    @Test func magicOnlyValueIsNotDecompressed() {
        let r = Decompressor.decompress(Data([0x1F, 0x8B]), using: .gzip)
        #expect(!r.isCompressed)
        #expect(r.error == nil)
    }

    @Test(arguments: [Compressor.gzip, .phpGZCompress, .zstd, .lz4, .snappy])
    func compressRoundTrips(_ compressor: Compressor) throws {
        let samples: [Data] = [Data("hello world".utf8), Data((0..<70_000).map { UInt8($0 % 251) }), Data([0x00]), Data()]
        for sample in samples {
            let packed = try Decompressor.compress(sample, using: compressor)
            #expect(try Decompressor.decode(packed, as: compressor) == sample)
            guard !sample.isEmpty else { continue }
            let r = Decompressor.decompress(packed, using: compressor)
            #expect(r.isCompressed)
            #expect(r.value == sample)
        }
    }

    @Test func brotliCompressionIsSupportedOrReportedUnsupported() throws {
        let sample = Data(String(repeating: "brotli ", count: 50).utf8)
        do {
            let packed = try Decompressor.compress(sample, using: .brotli)
            #expect(try Decompressor.decode(packed, as: .brotli) == sample)
        } catch let error as DecompressorError {
            #expect(error == .unsupported(.brotli))
        }
    }

    @Test func snappyRawAndFramedFixtures() throws {
        // The literal "abcd" followed by an 8-byte copy at offset 4 decodes to "abcdabcdabcd".
        let raw: [UInt8] = [12, 0x0C, 0x61, 0x62, 0x63, 0x64, 0x11, 0x04]
        // Tag 0x11 encodes type 01, length 4 + ((0x11 >> 2) & 7) = 8, and offset (0x11 >> 5) << 8 | 4 = 4.
        #expect(try Decompressor.decode(Data(raw), as: .snappy) == Data("abcdabcdabcd".utf8))

        var framed = Snappy.streamIdentifier
        let body: [UInt8] = [0, 0, 0, 0] + raw
        framed += [0x00, UInt8(body.count), 0, 0] + body
        framed += [0x01, 7, 0, 0, 0, 0, 0, 0, 0x78, 0x79, 0x7A]
        #expect(try Decompressor.decode(Data(framed), as: .snappy) == Data("abcdabcdabcdxyz".utf8))
        #expect(Decompressor.detect(Data(framed)) == .snappy)

        // A 2-byte offset copies 6 bytes from offset 3 after the literal "xyz".
        let copy2: [UInt8] = [9, 0x08, 0x78, 0x79, 0x7A, UInt8((6 - 1) << 2 | 2), 3, 0]
        #expect(try Decompressor.decode(Data(copy2), as: .snappy) == Data("xyzxyzxyz".utf8))

        let bad: [UInt8] = [20, 0x0C, 0x61, 0x62, 0x63, 0x64]
        #expect(throws: DecompressorError.self) { try Decompressor.decode(Data(bad), as: .snappy) }
        let r = Decompressor.decompress(Data(raw), using: .snappy)
        #expect(r.isCompressed && r.compressor == .snappy)
    }

    @Test func lz4AppleFramingAndRawBlock() throws {
        let payload = [UInt8]("apple framed lz4 payload".utf8)
        let block = LZ4.encodeLiteralBlock(payload)
        var apple: [UInt8] = Array("bv41".utf8) + DeflateContainers.littleEndian(UInt32(payload.count))
            + DeflateContainers.littleEndian(UInt32(block.count)) + block
        apple += Array("bv4-".utf8) + DeflateContainers.littleEndian(3) + Array("xyz".utf8)
        apple += Array("bv4$".utf8)
        #expect(try Decompressor.decode(Data(apple), as: .lz4) == Data(payload + Array("xyz".utf8)))
        #expect(Decompressor.detect(Data(apple)) == .lz4)

        // An overlapping 8-byte match at offset 2 extends "ab" to "ababababab".
        let rawBlock: [UInt8] = [0x24, 0x61, 0x62, 0x02, 0x00, 0x00]
        let decoded = try LZ4.decodeBlock(rawBlock)
        #expect(decoded == Array("ababababab".utf8) )
        let r = Decompressor.decompress(Data(rawBlock), using: .lz4)
        #expect(r.isCompressed)
        #expect(r.value == Data("ababababab".utf8))
    }

    @Test func backReferenceCopiesOverlappingAndDisjointRanges() {
        var overlapping: [UInt8] = Array("ab".utf8)
        overlapping.appendBackReference(distance: 2, length: 7)
        #expect(overlapping == Array("ababababa".utf8))

        var single: [UInt8] = [0x7A]
        single.appendBackReference(distance: 1, length: 100_000)
        #expect(single.count == 100_001)
        #expect(single.allSatisfy { $0 == 0x7A })

        var disjoint: [UInt8] = Array("0123456789".utf8)
        disjoint.appendBackReference(distance: 8, length: 3)
        #expect(disjoint == Array("0123456789234".utf8))
    }

    @Test func lz4BlockWithManyMatchesDecodes() throws {
        let window = lcgBytes(count: 1_000)
        // 1,000 literals (15 + 255 + 255 + 255 + 220) followed by an 18-byte match 1,000 bytes back.
        var block: [UInt8] = [0xFE, 255, 255, 255, 220] + window + [0xE8, 0x03]
        let matches = 200_000
        for n in 0..<matches {
            // One literal, then a match of 18 bytes from 1,000 bytes back.
            block += [0x1E, UInt8(truncatingIfNeeded: n), 0xE8, 0x03]
        }

        block += [0x10, 0x21]

        var expected = window + window.prefix(18)
        expected.reserveCapacity(1_018 + matches * 19 + 1)
        for n in 0..<matches {
            expected.append(UInt8(truncatingIfNeeded: n))
            let start = expected.count - 1_000
            for k in 0..<18 { expected.append(expected[start + k]) }
        }

        expected.append(0x21)

        let decoded = try LZ4.decodeBlock(block)
        #expect(decoded.count == expected.count)
        #expect(decoded == expected)
    }

    @Test func lz4LargeAppleFramedPayloadDecodes() throws {
        let payload = Array(repeating: lcgBytes(count: 1_000), count: 4_000).flatMap { $0 }
        let encoded = try AppleCompression.encode(payload, algorithm: COMPRESSION_LZ4)
        #expect(encoded.count < payload.count / 10)
        #expect(try LZ4.decompress(encoded) == payload)
    }

    @Test func zstdLargePayloadsDecode() throws {
        let lcg = Array(repeating: lcgBytes(count: 1_000), count: 4_000).flatMap { $0 }
        #expect(try Decompressor.decode(b64(Fixtures.large_lcg_zstd19), as: .zstd) == Data(lcg))

        let abc = [UInt8](String(repeating: "abc", count: 1_000_000).utf8)
        #expect(try Decompressor.decode(b64(Fixtures.large_abc_zstd19), as: .zstd) == Data(abc))
    }

    @Test func checksums() {
        #expect(Checksum.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(Checksum.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(Checksum.xxh32([]) == 0x02CC_5D05)
        #expect(Checksum.xxh32(Array("abc".utf8)) == 0x32D1_53FF)
    }
}

private func lcgBytes(count: Int) -> [UInt8] {
    var x: UInt32 = 1
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    for _ in 0..<count {
        x = (x &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
        bytes.append(UInt8(truncatingIfNeeded: x >> 16))
    }

    return bytes
}
