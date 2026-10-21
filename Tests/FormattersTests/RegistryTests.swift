import Foundation
@testable import Formatters
import Testing

struct RegistryTests {
    @Test func everyFormatHasARealFormatter() {
        for format in ValueFormat.allCases {
            #expect(FormatterRegistry.formatter(for: format).format == format)
        }

        #expect(ValueFormat.menuOrder.count == ValueFormat.allCases.count)
    }

    @Test func readOnlyFormatsThrowNotEditable() {
        for format in ValueFormat.allCases where !format.isEditable {
            #expect(throws: FormatterError.notEditable(format)) { try FormatterRegistry.parseEdited("1", as: format) }
        }
    }

    @Test func formatDecompressesWithConfiguredCompressor() throws {
        let json = Data(#"{"a":1}"#.utf8)
        let packed = try Decompressor.compress(json, using: .gzip)
        let r = FormatterRegistry.format(packed, as: .json, compressor: .gzip)
        #expect(r.isValid)
        #expect(r.isCompressed)
        #expect(r.detectedCompressor == .gzip)
        #expect(r.compressionError == nil)
        #expect(r.displayText(expanded: false) == #"{"a":1}"#)
    }

    @Test func compressionOffStillReportsDetectedCompressor() throws {
        let packed = try Decompressor.compress(Data("hello".utf8), using: .zstd)
        let r = FormatterRegistry.format(packed, as: .unicode)
        #expect(!r.isCompressed)
        #expect(r.detectedCompressor == .zstd)
        let auto = FormatterRegistry.format(packed, as: .unicode, options: FormatOptions(autoDecompress: true))
        #expect(auto.isCompressed)
        #expect(auto.text == "hello")
    }

    @Test func corruptCompressedValueReportsErrorAndShowsRaw() {
        let bogus = Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x01, 0x02])
        let r = FormatterRegistry.format(bogus, as: .hex, compressor: .zstd)
        #expect(!r.isCompressed)
        #expect(r.compressionError != nil)
        #expect(r.text == "28b52ffd000102")
        #expect(r.compressionError?.errorDescription?.hasPrefix("Invalid ZSTD data") == true)
        #expect(DecompressorError.unsupported(.zstd).errorDescription == "Unsupported compression: ZSTD data cannot be decoded.")
    }

    @Test func bestGuessPicksJSONTextOrHex() throws {
        #expect(FormatterRegistry.bestGuess(Data(#"{"x":[1,2]}"#.utf8)).format == .json)
        #expect(FormatterRegistry.bestGuess(Data("[1, 2]".utf8)).format == .json)
        #expect(FormatterRegistry.bestGuess(Data("42".utf8)).format == .unicode)
        #expect(FormatterRegistry.bestGuess(Data("hello\nworld".utf8)).format == .unicode)
        #expect(FormatterRegistry.bestGuess(Data([0x00, 0x01, 0xFF])).format == .hex)
        #expect(FormatterRegistry.bestGuess(Data("bell\u{07}".utf8)).format == .hex)
        let gz = try Decompressor.compress(Data(#"{"k":"v"}"#.utf8), using: .gzip)
        let guess = FormatterRegistry.bestGuess(gz)
        #expect(guess.format == .json)
        #expect(guess.result.isCompressed)
        #expect(guess.result.detectedCompressor == .gzip)
        #expect(guess.result.displayText(expanded: false) == #"{"k":"v"}"#)
    }

    @Test func editRoundTripWithCompression() throws {
        let written = try FormatterRegistry.parseEdited(#"{"a": 1}"#, as: .json, compressor: .gzip)
        #expect(Decompressor.detect(written) == .gzip)
        #expect(try Decompressor.decode(written, as: .gzip) == Data(#"{"a":1}"#.utf8))
        #expect(FormatterRegistry.serializeForEdit(written, as: .json, compressor: .gzip) == "{\n    \"a\": 1\n}")
    }

    @Test func printableChecks() {
        #expect(FormatterRegistry.isPrintable(Data("héllo".utf8)))
        #expect(!FormatterRegistry.isPrintable(Data([0xFF])))
        #expect(FormatterRegistry.isNonUnicode(Data([0x01])))
        #expect(!FormatterRegistry.isNonUnicode(Data("a\tb".utf8)))
        #expect(FormatterRegistry.isNonUnicodeFormat(.hex, isValid: true))
        #expect(!FormatterRegistry.isNonUnicodeFormat(.json, isValid: true))
    }

    @Test(arguments: ValueFormat.allCases)
    func neverCrashesOnArbitraryBytes(_ format: ValueFormat) {
        var generator = SystemRandomNumberGenerator()
        for length in [0, 1, 2, 3, 7, 16, 64, 300] {
            for _ in 0..<40 {
                let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
                _ = FormatterRegistry.format(data, as: format)
                _ = FormatterRegistry.serializeForEdit(data, as: format)
            }
        }
    }

    @Test(arguments: Compressor.allCases)
    func decompressorsNeverCrashOnArbitraryBytes(_ compressor: Compressor) {
        var generator = SystemRandomNumberGenerator()
        for length in [0, 1, 4, 5, 12, 40, 200] {
            for _ in 0..<60 {
                var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
                if let magic = compressor.magicBytes, bytes.count > magic.count {
                    bytes.replaceSubrange(0..<magic.count, with: magic)
                }

                _ = Decompressor.decompress(Data(bytes), using: compressor)
                _ = Decompressor.decompressAuto(Data(bytes))
            }
        }
    }
}
