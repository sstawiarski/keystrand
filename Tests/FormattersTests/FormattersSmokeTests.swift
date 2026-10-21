import Foundation
import Formatters
import Testing

struct FormattersSmokeTests {
    @Test func hexRoundTrip() throws {
        let bytes = Data([0x00, 0x7F, 0xFF])
        let text = FormatterRegistry.format(bytes, as: .hex).text
        #expect(text == "007fff")
        #expect(try FormatterRegistry.parseEdited(text, as: .hex) == bytes)
    }

    @Test func formatRawValuesAreStable() {
        #expect(ValueFormat.php.rawValue == "PHP serialized")
        #expect(Compressor.phpGZCompress.rawValue == "PHPGZCompress")
        #expect(ByteFormatter.format(1536, decimals: 1) == "1.5 KB")
        #expect(NumberFormatting.grouped(1234567) == "1,234,567")
    }
}
