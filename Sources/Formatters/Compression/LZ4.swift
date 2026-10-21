import Foundation

/// LZ4 block decoder, frame (`04 22 4d 18`), legacy frame (`02 21 4c 18`),
/// Apple framing (`bv41` / `bv4-` / `bv4$`) and literal-only frame encoder.
enum LZ4 {
    static let frameMagic: [UInt8] = [0x04, 0x22, 0x4D, 0x18]
    static let legacyMagic: [UInt8] = [0x02, 0x21, 0x4C, 0x18]
    static let maxOutput = 512 * 1024 * 1024

    /// Decodes one LZ4 block, appending to `output` (earlier output acts as the match window for linked blocks).
    static func decodeBlock(_ input: [UInt8], range: Range<Int>, into output: inout [UInt8], expectedSize: Int? = nil) throws {
        var i = range.lowerBound
        let end = range.upperBound
        let blockStart = output.count
        if let expectedSize { output.reserveCapacity(output.count + expectedSize) }
        while i < end {
            let token = input[i]
            i += 1
            var literalLength = Int(token >> 4)
            if literalLength == 15 {
                while true {
                    guard i < end else { throw ByteReaderError.truncated }
                    let b = input[i]
                    i += 1
                    literalLength += Int(b)
                    if b != 255 { break }
                }
            }

            guard literalLength <= end - i else { throw ByteReaderError("LZ4 literal runs past the block") }
            output.append(contentsOf: input[i..<i + literalLength])
            i += literalLength
            if i == end { break }
            guard i + 2 <= end else { throw ByteReaderError.truncated }
            let offset = Int(input[i]) | Int(input[i + 1]) << 8
            i += 2
            guard offset > 0, offset <= output.count else { throw ByteReaderError("LZ4 match offset out of range") }
            var matchLength = Int(token & 0x0F)
            if matchLength == 15 {
                while true {
                    guard i < end else { throw ByteReaderError.truncated }
                    let b = input[i]
                    i += 1
                    matchLength += Int(b)
                    if b != 255 { break }
                }
            }

            matchLength += 4
            if output.count + matchLength > maxOutput { throw ByteReaderError("LZ4 output too large") }
            if let expectedSize, output.count - blockStart + matchLength > expectedSize {
                throw ByteReaderError("LZ4 block larger than declared")
            }

            output.appendBackReference(distance: offset, length: matchLength)
        }

        if let expectedSize, output.count - blockStart != expectedSize {
            throw ByteReaderError("LZ4 block size mismatch")
        }
    }

    static func decodeBlock(_ input: [UInt8], expectedSize: Int? = nil) throws -> [UInt8] {
        var out: [UInt8] = []
        try decodeBlock(input, range: 0..<input.count, into: &out, expectedSize: expectedSize)
        return out
    }

    static func hasFrameMagic(_ input: [UInt8]) -> Bool { input.starts(with: frameMagic) }

    static func isAppleFramed(_ input: [UInt8]) -> Bool {
        input.count >= 4 && input[0] == 0x62 && input[1] == 0x76 && input[2] == 0x34
            && (input[3] == 0x31 || input[3] == 0x2D || input[3] == 0x24)
    }

    /// Frame, legacy frame, Apple framing, or (best effort) a bare block.
    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        if input.starts(with: frameMagic) || input.starts(with: legacyMagic) { return try decodeFrames(input) }
        if isAppleFramed(input) { return try decodeApple(input) }
        let out = try decodeBlock(input)
        guard !out.isEmpty else { throw ByteReaderError("empty LZ4 block") }
        return out
    }

    static func decodeFrames(_ input: [UInt8]) throws -> [UInt8] {
        var r = ByteReader(input)
        var output: [UInt8] = []
        while !r.isAtEnd {
            let magic = try r.u32LE()
            switch magic {
            case 0x184D_2204:
                try decodeFrameBody(&r, into: &output)
            case 0x184C_2102:
                try decodeLegacyBody(&r, into: &output)
            case 0x184D_2A50...0x184D_2A5F:
                try r.skip(Int(try r.u32LE()))
            default:
                throw ByteReaderError("unknown LZ4 frame magic")
            }
        }

        return output
    }

    private static func decodeFrameBody(_ r: inout ByteReader, into output: inout [UInt8]) throws {
        let descriptorStart = r.offset
        let flg = try r.u8()
        guard flg >> 6 == 1 else { throw ByteReaderError("unsupported LZ4 frame version") }
        let bd = try r.u8()
        let blockChecksum = flg & 0x10 != 0
        let hasContentSize = flg & 0x08 != 0
        let contentChecksum = flg & 0x04 != 0
        let hasDictID = flg & 0x01 != 0
        let maxBlock: Int
        switch (bd >> 4) & 0x07 {
        case 4: maxBlock = 64 * 1024
        case 5: maxBlock = 256 * 1024
        case 6: maxBlock = 1024 * 1024
        case 7: maxBlock = 4 * 1024 * 1024
        default: throw ByteReaderError("invalid LZ4 block size")
        }

        var contentSize: UInt64?
        if hasContentSize { contentSize = try r.u64LE() }
        if hasDictID { throw ByteReaderError("LZ4 dictionaries are not supported") }
        let descriptor = Array(r.bytes[descriptorStart..<r.offset])
        let headerChecksum = try r.u8()
        guard headerChecksum == UInt8((Checksum.xxh32(descriptor) >> 8) & 0xFF) else {
            throw ByteReaderError("LZ4 header checksum mismatch")
        }
        let frameStart = output.count
        while true {
            let raw = try r.u32LE()
            if raw == 0 { break }
            let size = Int(raw & 0x7FFF_FFFF)
            guard size <= maxBlock, size <= r.remaining else { throw ByteReaderError.truncated }
            if raw & 0x8000_0000 != 0 {
                output.append(contentsOf: r.bytes[r.offset..<r.offset + size])
            } else {
                try decodeBlock(r.bytes, range: r.offset..<r.offset + size, into: &output)
            }

            try r.skip(size)
            if blockChecksum { try r.skip(4) }
            if output.count > maxOutput { throw ByteReaderError("LZ4 output too large") }
        }

        if contentChecksum {
            let expected = try r.u32LE()
            guard expected == Checksum.xxh32(Array(output[frameStart...])) else {
                throw ByteReaderError("LZ4 content checksum mismatch")
            }
        }

        if let contentSize, UInt64(output.count - frameStart) != contentSize {
            throw ByteReaderError("LZ4 content size mismatch")
        }
    }

    private static func decodeLegacyBody(_ r: inout ByteReader, into output: inout [UInt8]) throws {
        while r.remaining >= 4 {
            let peek = UInt32(r.bytes[r.offset]) | UInt32(r.bytes[r.offset + 1]) << 8
                | UInt32(r.bytes[r.offset + 2]) << 16 | UInt32(r.bytes[r.offset + 3]) << 24
            if peek == 0x184C_2102 || peek == 0x184D_2204 { return }
            let size = Int(try r.u32LE())
            guard size <= r.remaining else { throw ByteReaderError.truncated }
            var block: [UInt8] = []
            try decodeBlock(r.bytes, range: r.offset..<r.offset + size, into: &block)
            output += block
            try r.skip(size)
        }

        if !r.isAtEnd { throw ByteReaderError.truncated }
    }

    static func decodeApple(_ input: [UInt8]) throws -> [UInt8] {
        var r = ByteReader(input)
        var output: [UInt8] = []
        while true {
            let tag = try r.read(4)
            guard tag[0] == 0x62, tag[1] == 0x76, tag[2] == 0x34 else { throw ByteReaderError("bad LZ4 block tag") }
            switch tag[3] {
            case 0x24: // bv4$
                return output
            case 0x31: // bv41
                let decoded = Int(try r.u32LE())
                let encoded = Int(try r.u32LE())
                guard encoded <= r.remaining else { throw ByteReaderError.truncated }
                // Apple blocks may reference earlier output, so decode into the shared buffer.
                let before = output.count
                try decodeBlock(r.bytes, range: r.offset..<r.offset + encoded, into: &output)
                guard output.count - before == decoded else { throw ByteReaderError("LZ4 block size mismatch") }
                try r.skip(encoded)
            case 0x2D: // bv4-
                let size = Int(try r.u32LE())
                output += try r.read(size)
            default:
                throw ByteReaderError("unknown LZ4 block tag")
            }
        }
    }

    /// Valid LZ4 frame storing the input as uncompressed blocks (readable by any LZ4 decoder).
    static func encodeFrame(_ input: [UInt8]) -> [UInt8] {
        let descriptor: [UInt8] = [0x64, 0x70] // version 01, independent blocks, content checksum; 4 MB blocks
        var out = frameMagic + descriptor
        out.append(UInt8((Checksum.xxh32(descriptor) >> 8) & 0xFF))
        let blockSize = 4 * 1024 * 1024
        var i = 0
        while i < input.count {
            let n = min(blockSize, input.count - i)
            out += DeflateContainers.littleEndian(UInt32(n) | 0x8000_0000)
            out += input[i..<i + n]
            i += n
        }

        out += [0, 0, 0, 0]
        out += DeflateContainers.littleEndian(Checksum.xxh32(input))
        return out
    }

    /// Encodes an LZ4 block containing only literals.
    static func encodeLiteralBlock(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        let n = input.count
        if n < 15 {
            out.append(UInt8(n << 4))
        } else {
            out.append(0xF0)
            var rest = n - 15
            while rest >= 255 {
                out.append(255)
                rest -= 255
            }

            out.append(UInt8(rest))
        }

        out += input
        return out
    }
}
