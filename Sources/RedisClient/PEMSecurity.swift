import CryptoKit
import Foundation
import RESP
import Security

public enum PEMSecurityError: Error, LocalizedError, Sendable {
    case invalidPEM(String)
    case importFailed(OSStatus)
    case identityNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidPEM(let what): return "Invalid PEM: \(what)"
        case .importFailed(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
            return "The private key could not be read (OSStatus \(status)). \(message)".trimmingCharacters(in: .whitespaces)
        case .identityNotFound: return "The private key does not belong to the client certificate."
        }
    }
}

/// Converts PEM to Security framework objects for TLS, accepting PKCS#1 (`BEGIN RSA PRIVATE KEY`),
/// PKCS#8 (`BEGIN PRIVATE KEY`) and SEC1 (`BEGIN EC PRIVATE KEY`) keys.
/// Identities are built in memory and never stored in a keychain.
public enum PEMSecurity {
    public struct PEMBlock: Hashable, Sendable {
        public var label: String
        public var der: Data
    }

    /// Every `-----BEGIN <label>----- ... -----END <label>-----` block in `pem`.
    public static func blocks(in pem: String) -> [PEMBlock] {
        var out: [PEMBlock] = []
        var label: String?
        var body = ""
        for rawLine in pem.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN "), line.hasSuffix("-----") {
                label = String(line.dropFirst(11).dropLast(5))
                body = ""
            } else if line.hasPrefix("-----END "), let current = label {
                if let der = Data(base64Encoded: body) { out.append(PEMBlock(label: current, der: der)) }
                label = nil
            } else if label != nil, !line.contains(":") {
                body += line
            }
        }

        return out
    }

    public static func certificates(fromPEM pem: String) throws -> [SecCertificate] {
        let certs = blocks(in: pem).filter { $0.label.contains("CERTIFICATE") }
        guard !certs.isEmpty else { throw PEMSecurityError.invalidPEM("no CERTIFICATE block found") }
        return try certs.map { block in
            guard let cert = SecCertificateCreateWithData(nil, block.der as CFData) else {
                throw PEMSecurityError.invalidPEM("certificate could not be decoded")
            }
            return cert
        }
    }

    public static func identity(certificatePEM: String, privateKeyPEM: String) throws -> SecIdentity {
        guard let certificate = try certificates(fromPEM: certificatePEM).first else {
            throw PEMSecurityError.invalidPEM("no certificate")
        }
        // SecIdentityCreate raises an Objective-C exception when the certificate key is unreadable.
        guard SecCertificateCopyKey(certificate) != nil else {
            throw PEMSecurityError.invalidPEM("the certificate's public key is not supported")
        }

        let key = try privateKey(fromPEM: privateKeyPEM)
        guard let identity = SecIdentityCreate(nil, certificate, key) else {
            throw PEMSecurityError.identityNotFound
        }
        return identity
    }

    static func privateKey(fromPEM pem: String) throws -> SecKey {
        guard let block = blocks(in: pem).first(where: { $0.label.contains("PRIVATE KEY") }) else {
            throw PEMSecurityError.invalidPEM("no PRIVATE KEY block found")
        }
        if block.label.contains("ENCRYPTED") {
            throw PEMSecurityError.invalidPEM("encrypted private keys are not supported")
        }

        switch block.label {
        case "RSA PRIVATE KEY":
            return try secKey(block.der, type: kSecAttrKeyTypeRSA)
        case "PRIVATE KEY":
            if let pkcs1 = rsaKey(inPKCS8: block.der) { return try secKey(pkcs1, type: kSecAttrKeyTypeRSA) }
            return try ellipticCurveKey(block.der)
        case "EC PRIVATE KEY":
            return try ellipticCurveKey(block.der)
        default:
            throw PEMSecurityError.invalidPEM("\(block.label) is not supported")
        }
    }

    private static let rsaEncryptionOID = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])

    /// The PKCS#1 key inside a PKCS#8 `PrivateKeyInfo`, or nil when it holds another algorithm.
    private static func rsaKey(inPKCS8 der: Data) -> Data? {
        guard let info = DERElement.parse(der)?.first, info.tag == 0x30,
              let fields = DERElement.parse(info.content), fields.count >= 3,
              fields[1].tag == 0x30, let algorithm = DERElement.parse(fields[1].content)?.first,
              algorithm.tag == 0x06, algorithm.content == rsaEncryptionOID,
              fields[2].tag == 0x04 else { return nil }
        return fields[2].content
    }

    /// Accepts SEC1 or PKCS#8 DER on the P-256, P-384 and P-521 curves.
    private static func ellipticCurveKey(_ der: Data) throws -> SecKey {
        let x963: Data
        if let key = try? P256.Signing.PrivateKey(derRepresentation: der) {
            x963 = key.x963Representation
        } else if let key = try? P384.Signing.PrivateKey(derRepresentation: der) {
            x963 = key.x963Representation
        } else if let key = try? P521.Signing.PrivateKey(derRepresentation: der) {
            x963 = key.x963Representation
        } else {
            throw PEMSecurityError.invalidPEM("only RSA and P-256, P-384 or P-521 EC private keys are supported")
        }

        return try secKey(x963, type: kSecAttrKeyTypeECSECPrimeRandom)
    }

    private static func secKey(_ data: Data, type: CFString) throws -> SecKey {
        let attributes = [kSecAttrKeyType: type, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attributes, &error) else {
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? Int(errSecParam)
            throw PEMSecurityError.importFailed(OSStatus(truncatingIfNeeded: code))
        }
        return key
    }
}

private struct DERElement {
    var tag: UInt8
    var content: Data

    /// The top-level elements of `data`, or nil when it is not well-formed DER.
    static func parse(_ data: Data) -> [DERElement]? {
        var elements: [DERElement] = []
        var index = data.startIndex
        while index < data.endIndex {
            let tag = data[index]
            index += 1
            guard index < data.endIndex else { return nil }
            var length = Int(data[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard (1...4).contains(count), data.endIndex - index >= count else { return nil }
                length = data[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }

            guard data.endIndex - index >= length else { return nil }
            elements.append(DERElement(tag: tag, content: Data(data[index..<index + length])))
            index += length
        }

        return elements
    }
}
