import Foundation

/// Zstandard decoder (RFC 8878) supporting frames, raw/RLE/compressed blocks, Huffman literals, FSE sequences and repeat offsets.
/// Dictionaries are unsupported. The encoder writes raw blocks only.
enum ZSTD {
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        var decoder = Decoder(input: input)
        return try decoder.run()
    }

    /// A valid zstd frame of raw blocks (no compression).
    static func encodeRaw(_ input: [UInt8]) -> [UInt8] {
        var out = magic
        // FCS flag 3 (8-byte content size), not single segment, no checksum, no dictionary.
        out.append(0xC0)
        out.append(0x58) // window descriptor: 2^(10 + 11) = 2 MB window
        var size = UInt64(input.count)
        for _ in 0..<8 {
            out.append(UInt8(size & 0xFF))
            size >>= 8
        }

        let maxBlock = 128 * 1024
        var i = 0
        repeat {
            let n = min(maxBlock, input.count - i)
            let last: UInt32 = i + n >= input.count ? 1 : 0
            let header = UInt32(n) << 3 | last
            out += [UInt8(header & 0xFF), UInt8(header >> 8 & 0xFF), UInt8(header >> 16 & 0xFF)]
            out += input[i..<i + n]
            i += n
        } while i < input.count

        return out
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = "ZSTD: " + d }
    }

    // MARK: - Bit readers

    /// Little-endian forward reader (FSE table descriptions).
    struct ForwardBits {
        let bytes: [UInt8]
        let start: Int
        let end: Int
        var bitPos = 0

        init(_ bytes: [UInt8], start: Int, end: Int) {
            self.bytes = bytes
            self.start = start
            self.end = end
        }

        func peek(_ n: Int) -> UInt64 {
            guard n > 0 else { return 0 }
            var v: UInt64 = 0
            let byteIndex = start + bitPos >> 3
            for k in 0..<8 where byteIndex + k < end {
                v |= UInt64(bytes[byteIndex + k]) << (8 * UInt64(k))
            }

            v >>= UInt64(bitPos & 7)
            return n >= 64 ? v : v & ((1 << UInt64(n)) - 1)
        }

        mutating func skip(_ n: Int) { bitPos += n }
        var bytesConsumed: Int { (bitPos + 7) >> 3 }
    }

    /// Reads bits from the end of a stream backwards (Huffman and FSE bitstreams).
    struct ReverseBits {
        let bytes: [UInt8]
        let start: Int
        let count: Int
        var position: Int

        init(_ bytes: [UInt8], start: Int, count: Int) throws {
            guard count > 0, start + count <= bytes.count else { throw Failure("empty bitstream") }
            let last = bytes[start + count - 1]
            guard last != 0 else { throw Failure("bitstream missing end marker") }
            self.bytes = bytes
            self.start = start
            self.count = count
            self.position = (count - 1) * 8 + (7 - last.leadingZeroBitCount)
        }

        private func extract(_ bitIndex: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            let byteIndex = bitIndex >> 3
            for k in 0..<8 where byteIndex + k < count {
                v |= UInt64(bytes[start + byteIndex + k]) << (8 * UInt64(k))
            }

            v >>= UInt64(bitIndex & 7)
            return v & ((1 << UInt64(n)) - 1)
        }

        func peek(_ n: Int) -> UInt64 {
            guard n > 0 else { return 0 }
            let low = position - n
            if low >= 0 { return extract(low, n) }
            guard position > 0 else { return 0 }
            return extract(0, position) << UInt64(-low)
        }

        mutating func read(_ n: Int) -> UInt64 {
            let v = peek(n)
            position -= n
            return v
        }
    }

    // MARK: - FSE

    struct FSETable {
        var symbols: [UInt8]
        var bits: [UInt8]
        var base: [UInt16]
        var accuracyLog: Int

        static func rle(_ symbol: UInt8) -> FSETable {
            FSETable(symbols: [symbol], bits: [0], base: [0], accuracyLog: 0)
        }

        init(symbols: [UInt8], bits: [UInt8], base: [UInt16], accuracyLog: Int) {
            self.symbols = symbols
            self.bits = bits
            self.base = base
            self.accuracyLog = accuracyLog
        }

        init(normalized: [Int], accuracyLog: Int) throws {
            let size = 1 << accuracyLog
            var symbols = [UInt8](repeating: 0, count: size)
            var next = [Int](repeating: 0, count: normalized.count)
            var high = size - 1
            for (s, n) in normalized.enumerated() {
                if n == -1 {
                    guard high >= 0 else { throw Failure("bad FSE distribution") }
                    symbols[high] = UInt8(s)
                    high -= 1
                    next[s] = 1
                } else {
                    next[s] = n
                }
            }

            let step = (size >> 1) + (size >> 3) + 3
            let mask = size - 1
            var position = 0
            for (s, n) in normalized.enumerated() where n > 0 {
                for _ in 0..<n {
                    symbols[position] = UInt8(s)
                    repeat { position = (position + step) & mask } while position > high
                }
            }

            guard position == 0 else { throw Failure("bad FSE distribution") }
            var bits = [UInt8](repeating: 0, count: size)
            var base = [UInt16](repeating: 0, count: size)
            for u in 0..<size {
                let s = Int(symbols[u])
                let state = next[s]
                next[s] += 1
                guard state > 0 else { throw Failure("bad FSE state") }
                let highBit = Int.bitWidth - 1 - state.leadingZeroBitCount
                let nb = accuracyLog - highBit
                bits[u] = UInt8(nb)
                base[u] = UInt16(truncatingIfNeeded: (state << nb) - size)
            }

            self.init(symbols: symbols, bits: bits, base: base, accuracyLog: accuracyLog)
        }

        /// Reads an FSE table description; returns the table and bytes consumed.
        static func read(_ bytes: [UInt8], at offset: Int, end: Int, maxSymbol: Int, maxLog: Int) throws -> (FSETable, Int) {
            var r = ForwardBits(bytes, start: offset, end: end)
            let accuracyLog = Int(r.peek(4)) + 5
            r.skip(4)
            guard accuracyLog <= maxLog else { throw Failure("FSE accuracy log too large") }
            var remaining = (1 << accuracyLog) + 1
            var threshold = 1 << accuracyLog
            var nbBits = accuracyLog + 1
            var symbol = 0
            var previousZero = false
            var normalized: [Int] = []
            while remaining > 1 && symbol <= maxSymbol {
                if previousZero {
                    var n0 = symbol
                    while r.peek(16) == 0xFFFF {
                        n0 += 24
                        r.skip(16)
                        guard r.start + (r.bitPos >> 3) < end else { throw Failure("truncated FSE description") }
                    }

                    while r.peek(2) == 3 {
                        n0 += 3
                        r.skip(2)
                    }

                    n0 += Int(r.peek(2))
                    r.skip(2)
                    guard n0 <= maxSymbol else { throw Failure("FSE symbol out of range") }
                    while symbol < n0 {
                        normalized.append(0)
                        symbol += 1
                    }
                }

                let maxValue = (2 * threshold - 1) - remaining
                var count: Int
                let low = Int(r.peek(nbBits - 1))
                if low < maxValue {
                    count = low
                    r.skip(nbBits - 1)
                } else {
                    count = Int(r.peek(nbBits))
                    if count >= threshold { count -= maxValue }
                    r.skip(nbBits)
                }

                count -= 1
                remaining -= abs(count)
                normalized.append(count)
                symbol += 1
                previousZero = count == 0
                while remaining < threshold && threshold > 1 {
                    nbBits -= 1
                    threshold >>= 1
                }
            }

            guard remaining == 1, r.start + r.bytesConsumed <= end else { throw Failure("corrupt FSE description") }
            return (try FSETable(normalized: normalized, accuracyLog: accuracyLog), r.bytesConsumed)
        }
    }

    struct FSEState {
        var state: Int

        init(_ table: FSETable, _ bits: inout ReverseBits) {
            state = Int(bits.read(table.accuracyLog))
        }

        func symbol(_ table: FSETable) -> Int { Int(table.symbols[state]) }

        mutating func update(_ table: FSETable, _ bits: inout ReverseBits) {
            state = Int(table.base[state]) + Int(bits.read(Int(table.bits[state])))
        }
    }

    // MARK: - Huffman

    struct HuffmanTable {
        var symbols: [UInt8]
        var lengths: [UInt8]
        var maxBits: Int

        init(weights: [Int]) throws {
            var total = 0
            for w in weights where w > 0 {
                guard w <= 11 else { throw Failure("Huffman weight too large") }
                total += 1 << (w - 1)
            }

            guard total > 0 else { throw Failure("empty Huffman table") }
            let maxBits = Int.bitWidth - total.leadingZeroBitCount
            let leftover = (1 << maxBits) - total
            guard leftover > 0, leftover & (leftover - 1) == 0 else { throw Failure("bad Huffman weights") }
            let lastWeight = Int.bitWidth - leftover.leadingZeroBitCount
            var all = weights
            all.append(lastWeight)
            guard maxBits <= 11 else { throw Failure("Huffman table too deep") }
            let size = 1 << maxBits
            var symbols = [UInt8](repeating: 0, count: size)
            var lengths = [UInt8](repeating: 0, count: size)
            var position = 0
            for w in 1...maxBits {
                for (s, weight) in all.enumerated() where weight == w {
                    let span = 1 << (w - 1)
                    let nb = UInt8(maxBits + 1 - w)
                    guard position + span <= size else { throw Failure("bad Huffman table") }
                    for k in position..<position + span {
                        symbols[k] = UInt8(s)
                        lengths[k] = nb
                    }

                    position += span
                }
            }

            guard position == size else { throw Failure("bad Huffman table") }
            self.symbols = symbols
            self.lengths = lengths
            self.maxBits = maxBits
        }

        /// Reads a Huffman tree description; returns the table and bytes consumed.
        static func read(_ bytes: [UInt8], at offset: Int, end: Int) throws -> (HuffmanTable, Int) {
            guard offset < end else { throw Failure("truncated Huffman description") }
            let header = Int(bytes[offset])
            var weights: [Int] = []
            if header < 128 {
                let size = header
                guard offset + 1 + size <= end, size > 0 else { throw Failure("truncated Huffman weights") }
                let (table, used) = try FSETable.read(bytes, at: offset + 1, end: offset + 1 + size, maxSymbol: 255, maxLog: 6)
                var bits = try ReverseBits(bytes, start: offset + 1 + used, count: size - used)
                var s1 = FSEState(table, &bits)
                var s2 = FSEState(table, &bits)
                while weights.count < 255 {
                    weights.append(s1.symbol(table))
                    s1.update(table, &bits)
                    if bits.position < 0 {
                        weights.append(s2.symbol(table))
                        break
                    }

                    weights.append(s2.symbol(table))
                    s2.update(table, &bits)
                    if bits.position < 0 {
                        weights.append(s1.symbol(table))
                        break
                    }
                }

                return (try HuffmanTable(weights: weights), 1 + size)
            } else {
                let count = header - 127
                let size = (count + 1) / 2
                guard offset + 1 + size <= end else { throw Failure("truncated Huffman weights") }
                for i in 0..<count {
                    let b = bytes[offset + 1 + i / 2]
                    weights.append(Int(i % 2 == 0 ? b >> 4 : b & 0x0F))
                }

                return (try HuffmanTable(weights: weights), 1 + size)
            }
        }

        func decodeStream(_ bytes: [UInt8], start: Int, count: Int, into out: inout [UInt8], regenerated: Int) throws {
            var bits = try ReverseBits(bytes, start: start, count: count)
            for _ in 0..<regenerated {
                let index = Int(bits.peek(maxBits))
                out.append(symbols[index])
                bits.position -= Int(lengths[index])
            }

            guard bits.position == 0 else { throw Failure("Huffman stream not fully consumed") }
        }
    }

    // MARK: - Sequence code tables

    static let llBase: [Int] = Array(0...15) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    static let llBits: [Int] = Array(repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    static let mlBase: [Int] = Array(3...34) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539]
    static let mlBits: [Int] = Array(repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]

    static let llDefault: [Int] = [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1]
    static let mlDefault: [Int] = [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                   1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1]
    static let ofDefault: [Int] = [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1]

    // MARK: - Decoder

    struct Decoder {
        let input: [UInt8]
        var offset = 0
        var output: [UInt8] = []
        var frameStart = 0
        var huffman: HuffmanTable?
        var llTable: FSETable?
        var ofTable: FSETable?
        var mlTable: FSETable?
        var repeats = [1, 4, 8]

        init(input: [UInt8]) {
            self.input = input
        }

        mutating func run() throws -> [UInt8] {
            guard input.count >= 4 else { throw Failure("too short") }
            while offset < input.count {
                guard offset + 4 <= input.count else { throw Failure("trailing bytes") }
                let m = UInt32(input[offset]) | UInt32(input[offset + 1]) << 8 | UInt32(input[offset + 2]) << 16 | UInt32(input[offset + 3]) << 24
                offset += 4
                if m == 0xFD2F_B528 {
                    try frame()
                } else if m & 0xFFFF_FFF0 == 0x184D_2A50 {
                    var r = ByteReader(input, offset: offset)
                    let size = Int(try r.u32LE())
                    try r.skip(size)
                    offset = r.offset
                } else {
                    throw Failure("bad magic number")
                }

                if output.count > LZ4.maxOutput { throw Failure("output too large") }
            }

            return output
        }

        mutating func frame() throws {
            var r = ByteReader(input, offset: offset)
            let descriptor = try r.u8()
            let fcsFlag = Int(descriptor >> 6)
            let singleSegment = descriptor & 0x20 != 0
            let checksum = descriptor & 0x04 != 0
            let dictFlag = Int(descriptor & 0x03)
            guard descriptor & 0x08 == 0 else { throw Failure("reserved bit set") }
            if !singleSegment { _ = try r.u8() }
            let dictSize = [0, 1, 2, 4][dictFlag]
            if dictSize > 0 {
                let id = try r.uintLE(dictSize)
                guard id == 0 else { throw Failure("dictionaries are not supported") }
            }

            var contentSize: UInt64?
            switch fcsFlag {
            case 0: if singleSegment { contentSize = UInt64(try r.u8()) }
            case 1: contentSize = UInt64(try r.u16LE()) + 256
            case 2: contentSize = UInt64(try r.u32LE())
            default: contentSize = try r.u64LE()
            }

            offset = r.offset
            frameStart = output.count
            huffman = nil
            llTable = nil
            ofTable = nil
            mlTable = nil
            repeats = [1, 4, 8]
            while true {
                guard offset + 3 <= input.count else { throw Failure("truncated block header") }
                let header = Int(input[offset]) | Int(input[offset + 1]) << 8 | Int(input[offset + 2]) << 16
                offset += 3
                let last = header & 1 != 0
                let type = (header >> 1) & 3
                let size = header >> 3
                switch type {
                case 0:
                    guard offset + size <= input.count else { throw Failure("truncated raw block") }
                    output.append(contentsOf: input[offset..<offset + size])
                    offset += size
                case 1:
                    guard offset < input.count else { throw Failure("truncated RLE block") }
                    output.append(contentsOf: repeatElement(input[offset], count: size))
                    offset += 1
                case 2:
                    guard offset + size <= input.count else { throw Failure("truncated compressed block") }
                    try compressedBlock(start: offset, end: offset + size)
                    offset += size
                default:
                    throw Failure("reserved block type")
                }

                if output.count - frameStart > LZ4.maxOutput { throw Failure("output too large") }
                if last { break }
            }

            if checksum {
                guard offset + 4 <= input.count else { throw Failure("missing checksum") }
                offset += 4
            }

            if let contentSize, UInt64(output.count - frameStart) != contentSize {
                throw Failure("content size mismatch")
            }
        }

        mutating func compressedBlock(start: Int, end: Int) throws {
            var pos = start
            let literals = try literalsSection(&pos, end: end)
            try sequencesSection(&pos, end: end, literals: literals)
        }

        mutating func literalsSection(_ pos: inout Int, end: Int) throws -> [UInt8] {
            guard pos < end else { throw Failure("truncated literals") }
            let b0 = Int(input[pos])
            let type = b0 & 3
            let sizeFormat = (b0 >> 2) & 3

            func byte(_ i: Int) throws -> Int {
                guard pos + i < end else { throw Failure("truncated literals header") }
                return Int(input[pos + i])
            }

            if type == 0 || type == 1 {
                var regenerated: Int
                switch sizeFormat {
                case 0, 2: regenerated = b0 >> 3; pos += 1
                case 1: regenerated = (b0 >> 4) + (try byte(1) << 4); pos += 2
                default: regenerated = (b0 >> 4) + (try byte(1) << 4) + (try byte(2) << 12); pos += 3
                }

                if type == 0 {
                    guard pos + regenerated <= end else { throw Failure("truncated raw literals") }
                    defer { pos += regenerated }
                    return Array(input[pos..<pos + regenerated])
                }

                guard pos < end else { throw Failure("truncated RLE literals") }
                defer { pos += 1 }
                return [UInt8](repeating: input[pos], count: regenerated)
            }

            let headerSize: Int
            let fieldBits: Int
            let streams: Int
            switch sizeFormat {
            case 0: headerSize = 3; fieldBits = 10; streams = 1
            case 1: headerSize = 3; fieldBits = 10; streams = 4
            case 2: headerSize = 4; fieldBits = 14; streams = 4
            default: headerSize = 5; fieldBits = 18; streams = 4
            }

            var header = 0
            for i in 0..<headerSize { header |= try byte(i) << (8 * i) }
            let mask = (1 << fieldBits) - 1
            let regenerated = (header >> 4) & mask
            let compressed = (header >> (4 + fieldBits)) & mask
            pos += headerSize
            let sectionEnd = pos + compressed
            guard sectionEnd <= end else { throw Failure("truncated compressed literals") }
            if type == 2 {
                let (table, used) = try HuffmanTable.read(input, at: pos, end: sectionEnd)
                huffman = table
                pos += used
            }

            guard let table = huffman else { throw Failure("missing Huffman table") }
            var out: [UInt8] = []
            out.reserveCapacity(regenerated)
            if streams == 1 {
                try table.decodeStream(input, start: pos, count: sectionEnd - pos, into: &out, regenerated: regenerated)
            } else {
                guard pos + 6 <= sectionEnd else { throw Failure("truncated jump table") }
                let s1 = Int(input[pos]) | Int(input[pos + 1]) << 8
                let s2 = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
                let s3 = Int(input[pos + 4]) | Int(input[pos + 5]) << 8
                let dataStart = pos + 6
                let s4 = sectionEnd - dataStart - s1 - s2 - s3
                guard s4 > 0 else { throw Failure("bad jump table") }
                let segment = (regenerated + 3) / 4
                let sizes = [s1, s2, s3, s4]
                var streamStart = dataStart
                for k in 0..<4 {
                    let count = k < 3 ? segment : regenerated - 3 * segment
                    guard count >= 0 else { throw Failure("bad literal stream sizes") }
                    try table.decodeStream(input, start: streamStart, count: sizes[k], into: &out, regenerated: count)
                    streamStart += sizes[k]
                }
            }

            pos = sectionEnd
            return out
        }

        mutating func readTable(mode: Int, pos: inout Int, end: Int, defaults: [Int], defaultLog: Int,
                                maxSymbol: Int, maxLog: Int, previous: FSETable?) throws -> FSETable {
            switch mode {
            case 0:
                return try FSETable(normalized: defaults, accuracyLog: defaultLog)
            case 1:
                guard pos < end else { throw Failure("truncated RLE table") }
                defer { pos += 1 }
                guard Int(input[pos]) <= maxSymbol else { throw Failure("RLE symbol out of range") }
                return FSETable.rle(input[pos])
            case 2:
                let (table, used) = try FSETable.read(input, at: pos, end: end, maxSymbol: maxSymbol, maxLog: maxLog)
                pos += used
                return table
            default:
                guard let previous else { throw Failure("repeat table without previous table") }
                return previous
            }
        }

        mutating func sequencesSection(_ pos: inout Int, end: Int, literals: [UInt8]) throws {
            guard pos < end else {
                output.append(contentsOf: literals)
                return
            }
            var count = Int(input[pos])
            pos += 1
            if count == 0 {
                output.append(contentsOf: literals)
                return
            }

            if count >= 128 {
                guard pos < end else { throw Failure("truncated sequence count") }
                if count == 255 {
                    guard pos + 1 < end else { throw Failure("truncated sequence count") }
                    count = Int(input[pos]) + (Int(input[pos + 1]) << 8) + 0x7F00
                    pos += 2
                } else {
                    count = ((count - 128) << 8) + Int(input[pos])
                    pos += 1
                }
            }

            guard pos < end else { throw Failure("truncated sequence modes") }
            let modes = Int(input[pos])
            pos += 1
            guard modes & 3 == 0 else { throw Failure("reserved sequence mode bits") }
            let ll = try readTable(mode: modes >> 6, pos: &pos, end: end, defaults: ZSTD.llDefault, defaultLog: 6,
                                   maxSymbol: 35, maxLog: 9, previous: llTable)
            let of = try readTable(mode: (modes >> 4) & 3, pos: &pos, end: end, defaults: ZSTD.ofDefault, defaultLog: 5,
                                   maxSymbol: 31, maxLog: 8, previous: ofTable)
            let ml = try readTable(mode: (modes >> 2) & 3, pos: &pos, end: end, defaults: ZSTD.mlDefault, defaultLog: 6,
                                   maxSymbol: 52, maxLog: 9, previous: mlTable)
            llTable = ll
            ofTable = of
            mlTable = ml

            var bits = try ReverseBits(input, start: pos, count: end - pos)
            var llState = FSEState(ll, &bits)
            var ofState = FSEState(of, &bits)
            var mlState = FSEState(ml, &bits)
            var literalIndex = 0
            for n in 0..<count {
                let ofCode = ofState.symbol(of)
                let llCode = llState.symbol(ll)
                let mlCode = mlState.symbol(ml)
                guard llCode < ZSTD.llBase.count, mlCode < ZSTD.mlBase.count, ofCode <= 31 else {
                    throw Failure("sequence code out of range")
                }
                let offsetValue = (1 << ofCode) + Int(bits.read(ofCode))
                let matchLength = ZSTD.mlBase[mlCode] + Int(bits.read(ZSTD.mlBits[mlCode]))
                let literalLength = ZSTD.llBase[llCode] + Int(bits.read(ZSTD.llBits[llCode]))

                var matchOffset: Int
                if offsetValue > 3 {
                    matchOffset = offsetValue - 3
                    repeats = [matchOffset, repeats[0], repeats[1]]
                } else {
                    var index = offsetValue - 1
                    if literalLength == 0 { index += 1 }
                    if index == 0 {
                        matchOffset = repeats[0]
                    } else {
                        matchOffset = index < 3 ? repeats[index] : repeats[0] - 1
                        if index > 1 { repeats[2] = repeats[1] }
                        repeats[1] = repeats[0]
                        repeats[0] = matchOffset
                    }
                }

                guard literalIndex + literalLength <= literals.count else { throw Failure("literal length out of range") }
                output.append(contentsOf: literals[literalIndex..<literalIndex + literalLength])
                literalIndex += literalLength

                guard matchOffset > 0, matchOffset <= output.count - frameStart else { throw Failure("match offset out of range") }
                guard output.count - frameStart + matchLength <= LZ4.maxOutput else { throw Failure("output too large") }
                output.appendBackReference(distance: matchOffset, length: matchLength)

                if n < count - 1 {
                    llState.update(ll, &bits)
                    mlState.update(ml, &bits)
                    ofState.update(of, &bits)
                }

                if bits.position < 0 { throw Failure("sequence bitstream overflow") }
            }

            guard bits.position == 0 else { throw Failure("sequence bitstream not fully consumed") }
            output.append(contentsOf: literals[literalIndex...])
        }
    }
}
