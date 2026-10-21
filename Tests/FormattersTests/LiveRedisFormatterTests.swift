import Foundation
@testable import Formatters
import RESP
import RedisClient
import Testing
import TestSupport

/// Binary values written to and read back from the live Redis at 127.0.0.1:6390 (DB 0, unique key prefix,
/// keys deleted afterwards) must decode exactly like the in-memory fixtures.
@Suite(.serialized)
struct LiveRedisFormatterTests {
    private func withConnection(_ body: (RedisConnection, String) async throws -> Void) async throws {
        let connection = try await RedisTestServer.makeConnection(db: RedisTestServer.DB.search)
        let prefix = RedisTestServer.uniquePrefix("formatters")
        do {
            try await body(connection, prefix)
        } catch {
            _ = try? await cleanup(connection, prefix)
            await connection.close()
            throw error
        }

        try await cleanup(connection, prefix)
        await connection.close()
    }

    private func cleanup(_ connection: RedisConnection, _ prefix: String) async throws {
        let reply = try await connection.execute(["KEYS", .string(prefix + "*")])
        for key in reply.arrayValue ?? [] {
            if let name = key.dataValue { _ = try await connection.execute(["DEL", .data(name)]) }
        }
    }

    private func roundTrip(_ connection: RedisConnection, key: String, value: Data) async throws -> Data {
        _ = try await connection.execute(["SET", .string(key), .data(value)])
        let reply = try await connection.execute(["GET", .string(key)])
        return try #require(reply.dataValue)
    }

    @Test(.tags(.live), RedisTestServer.live(.redis))
    func compressedValuesSurviveRedis() async throws {
        try await withConnection { connection, prefix in
            let cases: [(Compressor, String, Int, UInt32)] = [
                (.gzip, Fixtures.text_gzip, Fixtures.text_len, Fixtures.text_crc),
                (.zstd, Fixtures.text_zstd19, Fixtures.text_len, Fixtures.text_crc),
                (.lz4, Fixtures.text_lz4linked, Fixtures.text_len, Fixtures.text_crc),
                (.brotli, Fixtures.mixed_brotli, Fixtures.mixed_len, Fixtures.mixed_crc),
                (.phpGZCompress, Fixtures.repeat_zlib, Fixtures.repeat_len, Fixtures.repeat_crc),
            ]
            for (index, (compressor, b64, length, crc)) in cases.enumerated() {
                let stored = try await roundTrip(connection, key: prefix + "c\(index)", value: try #require(Data(base64Encoded: b64)))
                let result = Decompressor.decompress(stored, using: compressor)
                #expect(result.isCompressed, "\(compressor)")
                #expect(result.value.count == length)
                #expect(Checksum.crc32([UInt8](result.value)) == crc)
            }
        }
    }

    @Test(.tags(.live), RedisTestServer.live(.redis))
    func editedValuesAreWrittenAndReadBack() async throws {
        try await withConnection { connection, prefix in
            let edits: [(ValueFormat, String, Compressor)] = [
                (.json, #"{"id": 12345678901234567890, "name": "名字"}"#, .none),
                (.msgpack, #"{"a":[1,-2,3.5,null,true],"b":"x"}"#, .none),
                (.php, #"{"list":[1,2],"n":null}"#, .none),
                (.hex, "00ff10ab", .none),
                (.binary, "0000000111111110", .none),
                (.ascii, #"\x00\xe5bin\n"#, .none),
                (.vector32, "[1.5,-2,0.25]", .none),
                (.json, #"{"compressed":true}"#, .gzip),
                (.json, #"{"compressed":"zstd"}"#, .zstd),
                (.unicode, "snappy text", .snappy),
            ]
            for (index, (format, text, compressor)) in edits.enumerated() {
                let bytes = try FormatterRegistry.parseEdited(text, as: format, compressor: compressor)
                let stored = try await roundTrip(connection, key: prefix + "e\(index)", value: bytes)
                #expect(stored == bytes)
                let shown = FormatterRegistry.format(stored, as: format, compressor: compressor)
                #expect(shown.isValid, "\(format)")
                #expect(try FormatterRegistry.parseEdited(FormatterRegistry.serializeForEdit(stored, as: format, compressor: compressor),
                                                          as: format, compressor: .none)
                        == Decompressor.decompress(stored, using: compressor).value, "\(format)")
            }
        }
    }

    @Test(.tags(.live), RedisTestServer.live(.redis))
    func serverGeneratedBinaryRoundTripsThroughTextFormats() async throws {
        try await withConnection { connection, prefix in
            let key = prefix + "dump-source"
            _ = try await connection.execute(["RPUSH", .string(key), "a", "b", .data(Data([0x00, 0xFF]))])
            let dump = try #require(try await connection.execute(["DUMP", .string(key)]).dataValue)
            for format in [ValueFormat.hex, .binary, .ascii] {
                let text = FormatterRegistry.format(dump, as: format).text
                #expect(try FormatterRegistry.parseEdited(text, as: format) == dump, "\(format)")
            }

            #expect(FormatterRegistry.bestGuess(dump).format == .hex)
            let reply = try await connection.execute(["LRANGE", .string(key), "0", "-1"])
            let node = try ReplyNodeBuilder.build(reply, mode: .ascii, command: "LRANGE k 0 -1")
            #expect(try ReplyTextFormatter.text(node) == "1) \"a\"\n2) \"b\"\n3) \"\\x00\\xff\"")
        }
    }

    @Test(.tags(.live), RedisTestServer.live(.redis))
    func splitterArgumentsExecuteOnServer() async throws {
        try await withConnection { connection, prefix in
            let args = try CommandLineSplitter.split("SET \(prefix)split \"\\x00\\xffbin\"")
            _ = try await connection.execute(args.map { RedisArgument.data($0) })
            let value = try #require(try await connection.execute(["GET", .string(prefix + "split")]).dataValue)
            #expect(value == Data([0x00, 0xFF]) + Data("bin".utf8))
            #expect(FormatterRegistry.format(value, as: .ascii).text == #"\x00\xffbin"#)
        }
    }
}
