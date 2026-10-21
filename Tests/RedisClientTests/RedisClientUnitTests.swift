import Foundation
import RedisClient
import RESP
import Security
import Testing

struct MonitorLineParserTests {
    @Test func parsesTypicalLine() throws {
        let line = try MonitorLineParser.parse(#"1339518083.107412 [0 127.0.0.1:60866] "keys" "*""#)
        #expect(line.time == "1339518083.107412")
        #expect(line.database == 0)
        #expect(line.source == "127.0.0.1:60866")
        #expect(line.args == [Data("keys".utf8), Data("*".utf8)])
        #expect(line.raw.hasPrefix("1339518083"))
    }

    @Test func parsesLuaUnixAndIPv6Sources() throws {
        #expect(try MonitorLineParser.parse(#"1.5 [3 lua] "set" "k" "v""#).source == "lua")
        #expect(try MonitorLineParser.parse(#"1.5 [12 unix:/tmp/redis.sock] "ping""#).database == 12)
        #expect(try MonitorLineParser.parse(#"1.5 [12 unix:/tmp/redis.sock] "ping""#).source == "unix:/tmp/redis.sock")
        #expect(try MonitorLineParser.parse(#"1.5 [0 [::1]:5000] "ping""#).source == "[::1]:5000")
    }

    @Test func decodesEscapes() throws {
        let line = try MonitorLineParser.parse(#"1.0 [0 1.2.3.4:5] "set" "a\"b" "c\\d" "\n\r\t\a\b" "\x00\xff\xzz""#)
        #expect(line.args[1] == Data("a\"b".utf8))
        #expect(line.args[2] == Data("c\\d".utf8))
        #expect(line.args[3] == Data([0x0A, 0x0D, 0x09, 0x07, 0x08]))
        #expect(line.args[4] == Data([0x00, 0xFF]) + Data("xzz".utf8))
    }

    @Test func stripsBracketFromTime() throws {
        let line = try MonitorLineParser.parse(#"1339518083.107412[x [0 127.0.0.1:1] "get" "k""#)
        #expect(line.time == "1339518083.107412")
        #expect(line.args.count == 2)
    }

    @Test func emptyArgsAndSpaces() throws {
        let line = try MonitorLineParser.parse(#"1.0 [0 lua] "set" "" "a b""#)
        #expect(line.args == [Data("set".utf8), Data(), Data("a b".utf8)])
    }

    @Test func rejectsGarbage() {
        #expect(throws: MonitorLineParseError.self) { try MonitorLineParser.parse("OK") }
        #expect(throws: MonitorLineParseError.self) { try MonitorLineParser.parse(#"1.0 [x lua] "a""#) }
        #expect(throws: MonitorLineParseError.self) { try MonitorLineParser.parse(#"1.0 [0 lua] "unterminated"#) }
        #expect(throws: MonitorLineParseError.self) { try MonitorLineParser.parse(#"1.0 [0 lua] bare"#) }
    }
}

struct PubSubFrameParserTests {
    @Test func resp2Messages() {
        let message = PubSubFrameParser.parse(.bulkArray(["message", "ch", "hello"]))
        #expect(message?.kind == .message)
        #expect(message?.channel == Data("ch".utf8))
        #expect(message?.message == Data("hello".utf8))
        let pmessage = PubSubFrameParser.parse(.bulkArray(["pmessage", "c*", "chan", "x"]))
        #expect(pmessage?.kind == .pmessage)
        #expect(pmessage?.pattern == Data("c*".utf8))
        #expect(pmessage?.channel == Data("chan".utf8))
        #expect(PubSubFrameParser.parse(.bulkArray(["smessage", "s", "y"]))?.kind == .smessage)
    }

    @Test func confirmations() {
        let sub = PubSubFrameParser.parse(.array([.bulk("subscribe"), .bulk("ch"), .integer(1)]))
        #expect(sub?.kind == .subscribe && sub?.subscriptionCount == 1)
        let psub = PubSubFrameParser.parse(.push([.bulk("psubscribe"), .bulk("p*"), .integer(2)]))
        #expect(psub?.kind == .psubscribe && psub?.pattern == Data("p*".utf8))
        let unsub = PubSubFrameParser.parse(.array([.bulk("unsubscribe"), .bulkString(nil), .integer(0)]))
        #expect(unsub?.kind == .unsubscribe && unsub?.subscriptionCount == 0)
        #expect(PubSubFrameParser.isConfirmation(.punsubscribe))
        #expect(!PubSubFrameParser.isConfirmation(.pmessage))
    }

    @Test func ignoresOtherFrames() {
        #expect(PubSubFrameParser.parse(.bulkArray(["pong", ""])) == nil)
        #expect(PubSubFrameParser.parse(.ok) == nil)
        #expect(PubSubFrameParser.parse(.bulkArray(["message", "only-channel"])) == nil)
        #expect(PubSubFrameParser.parse(.push([.bulk("invalidate"), .bulkArray(["k"])])) == nil)
    }
}

struct SentinelParsingTests {
    @Test func parsesMasters() {
        let reply: RESPValue = .array([
            .bulkArray(["name", "mymaster", "ip", "10.0.0.1", "port", "6379", "flags", "master", "num-slaves", "2"]),
            .bulkArray(["name", "other", "ip", "10.0.0.2", "port", "6380", "flags", "master,s_down,o_down", "num-slaves", "0"]),
            .bulkArray(["broken"]),
        ])
        let masters = SentinelResolver.parseMasters(reply)
        #expect(masters.count == 2)
        #expect(masters[0] == SentinelMasterInfo(name: "mymaster", host: "10.0.0.1", port: 6379, numberOfSlaves: 2, status: "active"))
        #expect(masters[1].status == "down")
        let resp3 = RESPValue.array([.map([(.bulk("name"), .bulk("m")), (.bulk("ip"), .bulk("h")), (.bulk("port"), .bulk("1"))])])
        #expect(SentinelResolver.parseMasters(resp3).first?.endpoint == RedisEndpoint(host: "h", port: 1))
    }

    @Test func parsesAddressAndSentinels() {
        #expect(SentinelResolver.parseMasterAddress(.bulkArray(["10.0.0.9", "6390"])) == RedisEndpoint(host: "10.0.0.9", port: 6390))
        #expect(SentinelResolver.parseMasterAddress(.array(nil)) == nil)
        let sentinels = SentinelResolver.parseSentinels(.array([.bulkArray(["name", "x", "ip", "10.0.0.5", "port", "26379"])]))
        #expect(sentinels == [RedisEndpoint(host: "10.0.0.5", port: 26379)])
    }

    @Test func factoryRequiresMasterName() async {
        let descriptor = RedisClientDescriptor(
            topology: .sentinel(masterName: "", sentinels: [], sentinelUsername: nil, sentinelPassword: nil),
            connection: RedisConnectionConfig())
        await #expect(throws: RedisClientError.self) { _ = try await RedisClientFactory().makeClient(descriptor) }
    }
}

struct SSHTunnelTests {
    @Test func picksDistinctFreePorts() throws {
        var ports = Set<Int>()
        for _ in 0..<5 {
            let port = try SSHTunnel.pickFreePort()
            #expect(port > 1024 && port <= 65_535)
            ports.insert(port)
        }

        #expect(ports.count >= 2)
    }

    @Test func probeReportsClosedPort() throws {
        let port = try SSHTunnel.pickFreePort()
        #expect(!SSHTunnel.canConnect(port: port))
    }

    @Test func passwordArguments() {
        let options = SSHTunnelOptions(sshHost: "bastion.example.com", sshPort: 2222, username: "deploy",
                                       auth: .password("hunter2"), remoteHost: "10.0.0.7", remotePort: 6379,
                                       connectTimeout: 7.2)
        let args = SSHTunnel.arguments(options: options, localPort: 50_001, keyPath: nil, usesAskpass: true)
        #expect(args.first == "-N")
        #expect(args.last == "bastion.example.com")
        #expect(args.contains("127.0.0.1:50001:10.0.0.7:6379"))
        #expect(pair(args, "-p") == "2222")
        #expect(pair(args, "-l") == "deploy")
        #expect(args.contains("ExitOnForwardFailure=yes"))
        #expect(args.contains("StrictHostKeyChecking=accept-new"))
        #expect(args.contains("BatchMode=no"))
        #expect(args.contains("ConnectTimeout=8"))
        #expect(args.contains("PubkeyAuthentication=no"))
        #expect(!args.joined(separator: " ").contains("hunter2"))
        #expect(!args.contains("-i"))
    }

    @Test func keyArguments() {
        let options = SSHTunnelOptions(sshHost: "h", username: "u", auth: .privateKey(pem: "KEY", passphrase: nil),
                                       remoteHost: "::1", remotePort: 6379)
        let args = SSHTunnel.arguments(options: options, localPort: 4000, keyPath: "/tmp/k", usesAskpass: false)
        #expect(pair(args, "-i") == "/tmp/k")
        #expect(args.contains("IdentitiesOnly=yes"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("127.0.0.1:4000:[::1]:6379"))
        #expect(pair(args, "-p") == "22")
    }

    @Test func remoteRewrite() {
        let options = SSHTunnelOptions(sshHost: "h", username: "u", auth: .password("p"), remoteHost: "a", remotePort: 1)
        let moved = options.with(remote: RedisEndpoint(host: "b", port: 2))
        #expect(moved.remoteHost == "b" && moved.remotePort == 2 && moved.sshHost == "h")
    }

    @Test func failsCleanlyWhenSSHCannotConnect() async throws {
        let options = SSHTunnelOptions(sshHost: "127.0.0.1", sshPort: try SSHTunnel.pickFreePort(), username: "nobody",
                                       auth: .password("x"), remoteHost: "127.0.0.1", remotePort: 6390, connectTimeout: 2)
        let tunnel = SSHTunnel(options: options)
        await #expect(throws: RedisClientError.self) { try await tunnel.start() }
        #expect(await tunnel.localPort == nil)
        #expect(await tunnel.isRunning == false)
    }

    private func pair(_ args: [String], _ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

struct ConnectionScriptRunnerTests {
    private let runner = ConnectionScriptRunner(timeout: 5, shell: "/bin/sh")

    @Test func success() async throws {
        let result = try await runner.run("echo hello; echo oops >&2")
        #expect(result.succeeded)
        #expect(result.outputTail.contains("hello"))
        #expect(result.outputTail.contains("oops"))
    }

    @Test func exitCodeAndMessage() async throws {
        let result = try await runner.run("echo failing; exit 3")
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
        #expect(result.failureMessage(.preConnect, timeout: 5) == "The pre-connection script failed with exit code 3.\nfailing")
        await #expect(throws: RedisClientError.self) { try await runner.runOrThrow("exit 1", kind: .preConnect) }
    }

    @Test func timeoutKillsProcessGroup() async throws {
        let quick = ConnectionScriptRunner(timeout: 0.5, shell: "/bin/sh")
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await quick.run("sleep 30 & sleep 30")
        #expect(result.timedOut)
        #expect(clock.now - start < .seconds(5))
        #expect(result.failureMessage(.preConnect, timeout: 0.5).hasPrefix("The pre-connection script did not finish within"))
    }

    @Test func signal() async throws {
        let result = try await runner.run("kill -TERM $$")
        #expect(result.signal == SIGTERM)
        #expect(result.failureMessage(.preConnect, timeout: 5).hasPrefix("The pre-connection script stopped on signal"))
    }

    @Test func outputTailIsCapped() async throws {
        let result = try await runner.run("i=0; while [ $i -lt 600 ]; do echo 0123456789; i=$((i+1)); done")
        #expect(result.outputTail.count == 2000)
    }

    @Test func postDisconnectFailureNamesThatScript() async throws {
        let result = try await runner.run("exit 4")
        #expect(result.failureMessage(.postDisconnect, timeout: 5) == "The post-disconnect script failed with exit code 4.")
        do {
            try await runner.runOrThrow("exit 4", kind: .postDisconnect)
            Issue.record("expected script failure")
        } catch RedisClientError.scriptFailed(let kind, _) {
            #expect(kind == .postDisconnect)
        }
    }

    @Test func cancellationStopsTheScript() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("rgtest-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task { try await runner.run("echo $$ > '\(pidFile.path)'; sleep 30") }
        var pid: pid_t?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(for: .milliseconds(50))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        let scriptPID = try #require(pid)
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await #expect(throws: RedisClientError.self) { try await task.value }
        #expect(clock.now - start < .seconds(3))
        #expect(kill(scriptPID, 0) == -1)
    }

    @Test func termTrappingScriptIsKilled() async throws {
        let quick = ConnectionScriptRunner(timeout: 0.5, shell: "/bin/sh")
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await quick.run("trap '' TERM; while true; do sleep 0.1; done # \(UUID().uuidString)")
        #expect(result.timedOut)
        #expect(clock.now - start < .seconds(4))
    }

    @Test func outputTailKeepsInvalidUTF8() async throws {
        let result = try await runner.run("printf '\\377tail-text'")
        #expect(result.outputTail.hasSuffix("tail-text"))
    }

    @Test func blankScriptsAreNotRunnable() {
        #expect(ConnectionScriptRunner.runnable(nil) == nil)
        #expect(ConnectionScriptRunner.runnable(" \n\t") == nil)
        #expect(ConnectionScriptRunner.runnable("  true\n") == "true")
    }
}

struct PEMSecurityTests {
    private static let openssl = "/usr/bin/openssl"

    /// Generates a self-signed cert + key with the system openssl; nil if unavailable.
    private func generate(_ keyArgs: [String], keyConversion: [String]? = nil,
                          cn: String = "keystrand-test") throws -> (cert: String, key: String)? {
        guard FileManager.default.isExecutableFile(atPath: Self.openssl) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rgtest-pem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyPath = dir.appendingPathComponent("key.pem").path
        let certPath = dir.appendingPathComponent("cert.pem").path

        func run(_ args: [String]) throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.openssl)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }

        guard try run(keyArgs + ["-out", keyPath]) else { return nil }
        if let keyConversion {
            let converted = dir.appendingPathComponent("key2.pem").path
            guard try run(keyConversion + ["-in", keyPath, "-out", converted]) else { return nil }
            try FileManager.default.removeItem(atPath: keyPath)
            try FileManager.default.moveItem(atPath: converted, toPath: keyPath)
        }

        guard try run(["req", "-new", "-x509", "-key", keyPath, "-out", certPath, "-days", "2", "-subj", "/CN=\(cn)"]) else {
            return nil
        }
        let cert = try String(contentsOfFile: certPath, encoding: .utf8)
        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir)
        return (cert, key)
    }

    @Test func parsesCertificates() throws {
        guard let pair = try generate(["genrsa", "2048"]) else { return }
        let certs = try PEMSecurity.certificates(fromPEM: pair.cert + "\n" + pair.cert)
        #expect(certs.count == 2)
        #expect(SecCertificateCopySubjectSummary(certs[0]) as String? == "keystrand-test")
        #expect(throws: PEMSecurityError.self) { try PEMSecurity.certificates(fromPEM: "not a pem") }
    }

    @Test func blocksSplitLabels() {
        let pem = "junk\n-----BEGIN CERTIFICATE-----\nAAEC\n-----END CERTIFICATE-----\r\n-----BEGIN RSA PRIVATE KEY-----\nAwQ=\n-----END RSA PRIVATE KEY-----\n"
        let blocks = PEMSecurity.blocks(in: pem)
        #expect(blocks.map(\.label) == ["CERTIFICATE", "RSA PRIVATE KEY"])
        #expect(blocks[0].der == Data([0, 1, 2]))
        #expect(blocks[1].der == Data([3, 4]))
    }

    /// Builds an identity and checks that it carries the PEM certificate and a key that signs for it.
    private func expectIdentity(_ pair: (cert: String, key: String)) throws {
        let identity = try PEMSecurity.identity(certificatePEM: pair.cert, privateKeyPEM: pair.key)
        var certificate: SecCertificate?
        var key: SecKey?
        #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
        #expect(SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess)
        let expected = try PEMSecurity.certificates(fromPEM: pair.cert)[0]
        #expect(certificate.map { SecCertificateCopyData($0) as Data } == SecCertificateCopyData(expected) as Data)
        let certificateKey = try #require(SecCertificateCopyKey(expected))
        let identityKey = try #require(key.flatMap(SecKeyCopyPublicKey))
        #expect(SecKeyCopyExternalRepresentation(identityKey, nil) as Data?
            == SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?)
    }

    @Test func identityFromPKCS8RSAKey() throws {
        // openssl 3 / LibreSSL `genpkey` writes PKCS#8 (`BEGIN PRIVATE KEY`).
        guard let pair = try generate(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"]) else { return }
        #expect(pair.key.contains("BEGIN PRIVATE KEY"))
        try expectIdentity(pair)
    }

    @Test func identityFromPKCS1RSAKey() throws {
        guard let pair = try generate(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"],
                                      keyConversion: ["rsa", "-traditional"]) ?? (try generate(["genrsa", "2048"])) else { return }
        guard pair.key.contains("BEGIN RSA PRIVATE KEY") else { return }
        try expectIdentity(pair)
    }

    @Test func identityFromSEC1ECKey() throws {
        guard let pair = try generate(["ecparam", "-name", "prime256v1", "-genkey", "-noout"]) else { return }
        #expect(pair.key.contains("EC PRIVATE KEY"))
        try expectIdentity(pair)
    }

    @Test func identityFromPKCS8ECKey() throws {
        guard let pair = try generate(["ecparam", "-name", "prime256v1", "-genkey", "-noout"],
                                      keyConversion: ["pkcs8", "-topk8", "-nocrypt"]) else { return }
        #expect(pair.key.contains("BEGIN PRIVATE KEY"))
        try expectIdentity(pair)
    }

    @Test func identityFromP384KeyWithParameters() throws {
        guard let pair = try generate(["ecparam", "-name", "secp384r1", "-genkey"]) else { return }
        #expect(pair.key.contains("EC PARAMETERS"))
        try expectIdentity(pair)
    }

    @Test func identityIsRepeatableAndNeverStoredInAKeychain() throws {
        let cn = "keystrand-test-\(UUID().uuidString)"
        guard let pair = try generate(["genrsa", "2048"], cn: cn) else { return }
        try expectIdentity(pair)
        try expectIdentity(pair)

        func storedCount(_ itemClass: CFString) -> Int {
            let query = [kSecClass: itemClass, kSecMatchSubjectWholeString: cn, kSecMatchLimit: kSecMatchLimitAll,
                         kSecReturnRef: true] as CFDictionary
            var result: CFTypeRef?
            guard SecItemCopyMatching(query, &result) == errSecSuccess else { return 0 }
            return (result as? [AnyObject])?.count ?? 0
        }

        #expect(storedCount(kSecClassCertificate) == 0)
        #expect(storedCount(kSecClassIdentity) == 0)
        try expectIdentity(pair)
    }

    @Test func rejectsKeyOfAnotherCertificate() throws {
        guard let first = try generate(["genrsa", "2048"]), let second = try generate(["genrsa", "2048"]) else { return }
        do {
            _ = try PEMSecurity.identity(certificatePEM: first.cert, privateKeyPEM: second.key)
            Issue.record("expected a key mismatch")
        } catch PEMSecurityError.identityNotFound {}
    }

    @Test func rejectsCertificateWithExplicitCurveParameters() throws {
        guard let explicit = try generate(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-param_enc", "explicit"]),
              let rsa = try generate(["genrsa", "2048"]) else { return }
        #expect(throws: PEMSecurityError.self) {
            _ = try PEMSecurity.identity(certificatePEM: explicit.cert, privateKeyPEM: rsa.key)
        }
        #expect(throws: PEMSecurityError.self) {
            _ = try PEMSecurity.identity(certificatePEM: explicit.cert, privateKeyPEM: explicit.key)
        }
    }

    @Test func rejectsEncryptedAndUnsupportedKeys() throws {
        guard let pair = try generate(["genrsa", "2048"]) else { return }
        for key in ["-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAEC\n-----END ENCRYPTED PRIVATE KEY-----",
                    "-----BEGIN DSA PRIVATE KEY-----\nAAEC\n-----END DSA PRIVATE KEY-----",
                    "-----BEGIN PRIVATE KEY-----\nAAEC\n-----END PRIVATE KEY-----",
                    "-----BEGIN RSA PRIVATE KEY-----\nAAEC\n-----END RSA PRIVATE KEY-----"] {
            #expect(throws: PEMSecurityError.self) { _ = try PEMSecurity.identity(certificatePEM: pair.cert, privateKeyPEM: key) }
        }
    }

    @Test func rejectsMissingKey() {
        #expect(throws: (any Error).self) {
            _ = try PEMSecurity.identity(certificatePEM: "-----BEGIN CERTIFICATE-----\nAAEC\n-----END CERTIFICATE-----",
                                         privateKeyPEM: "nope")
        }
    }
}

struct MockRedisClientTests {
    @Test func scriptedRepliesAndRecording() async throws {
        let client = MockRedisClient(responses: ["PING": .simpleString("PONG"), "GET a": .bulk("1")])
        await client.enqueue([.integer(1), .integer(2)], for: "INCR")
        #expect(try await client.execute("PING") == .simpleString("PONG"))
        #expect(try await client.execute("GET", "a") == .bulk("1"))
        #expect(try await client.execute("GET", "b") == .null)
        #expect(try await client.execute("INCR", "x") == .integer(1))
        #expect(try await client.execute("INCR", "x") == .integer(2))
        #expect(try await client.execute("INCR", "x") == .null)
        #expect(await client.executedCommandStrings == ["PING", "GET a", "GET b", "INCR x", "INCR x", "INCR x"])
    }

    @Test func errorsAndTransportFailures() async throws {
        let client = MockRedisClient(handler: { $0.first == Data("BAD".utf8) ? .error(RESPError("ERR bad")) : nil })
        await #expect(throws: RedisClientError.self) { _ = try await client.execute("BAD") }
        #expect(try await client.pipeline([["BAD"], ["OK"]]).first?.isError == true)
        #expect(try await client.send(["BAD"]).isError)
        await client.setTransportError(.connectionClosed)
        await #expect(throws: RedisClientError.self) { _ = try await client.pipeline([["PING"]]) }
        await client.close()
        #expect(await client.isClosed)
    }
}
