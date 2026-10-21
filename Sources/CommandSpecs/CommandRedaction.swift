import Foundation

/// Masks passwords before saving CLI or Workbench history.
/// Handles AUTH, HELLO AUTH, MIGRATE AUTH/AUTH2, ACL SETUSER password rules, CONFIG SET passwords and TLS key passphrases,
/// and SENTINEL SET auth-pass. Preserves the rest of the line as typed.
public enum CommandRedaction {
    public static let mask = "******"

    static let secretConfigParameters: Set<String> = [
        "requirepass", "masterauth", "tls-key-file-pass", "tls-client-key-file-pass", "sentinel-pass",
    ]
    static let secretSentinelOptions: Set<String> = ["auth-pass"]

    /// Replaces secrets with `mask`, preserving ACL rule prefixes (`>`, `<`, `#`). Skips a leading repeat count (`3 AUTH pw`).
    public static func redact(_ line: String) -> String {
        let tokens = CommandLineTokenizer.tokenize(line).tokens
        guard !tokens.isEmpty else { return line }
        let offset = tokens.count > 1 && Double(tokens[0].text) != nil ? 1 : 0
        let words = tokens.dropFirst(offset).map(\.text)
        let secrets = secretArguments(words)
        guard !secrets.isEmpty else { return line }
        let text = NSMutableString(string: line)
        for (index, replacement) in secrets.sorted(by: { $0.key > $1.key }) {
            text.replaceCharacters(in: tokens[index + offset].range, with: replacement)
        }

        return text as String
    }

    /// Redacts each command in a `\r\n`-joined group.
    public static func redactLines(_ text: String) -> String {
        guard text.contains("\r\n") else { return redact(text) }
        return text.components(separatedBy: "\r\n").map(redact).joined(separator: "\r\n")
    }

    /// Maps secret argument indexes to replacement text. The command name is index 0.
    static func secretArguments(_ words: [String]) -> [Int: String] {
        guard let name = words.first?.uppercased() else { return [:] }
        let upper = words.map { $0.uppercased() }
        var out: [Int: String] = [:]
        switch name {
        case "AUTH":
            if words.count == 2 {
                out[1] = mask
            } else if words.count > 2 {
                for index in 2..<words.count { out[index] = mask }
            }
        case "HELLO":
            if let auth = upper.firstIndex(of: "AUTH"), auth + 2 < words.count { out[auth + 2] = mask }
        case "MIGRATE":
            for (index, word) in upper.enumerated() {
                if word == "AUTH", index + 1 < words.count { out[index + 1] = mask }
                if word == "AUTH2", index + 2 < words.count { out[index + 2] = mask }
            }
        case "ACL":
            guard upper.count > 2, upper[1] == "SETUSER" else { break }
            for index in 3..<words.count {
                guard let prefix = words[index].first, [">", "<", "#"].contains(prefix) else { continue }
                out[index] = String(prefix) + mask
            }
        case "CONFIG":
            guard upper.count > 3, upper[1] == "SET" else { break }
            var index = 2
            while index + 1 < words.count {
                if secretConfigParameters.contains(words[index].lowercased()) { out[index + 1] = mask }
                index += 2
            }
        case "SENTINEL":
            if upper.count > 4, upper[1] == "SET" {
                var index = 3
                while index + 1 < words.count {
                    if secretSentinelOptions.contains(words[index].lowercased()) { out[index + 1] = mask }
                    index += 2
                }
            } else if upper.count > 4, upper[1] == "CONFIG", upper[2] == "SET",
                      secretConfigParameters.contains(words[3].lowercased()) {
                out[4] = mask
            }
        default:
            break
        }

        return out
    }
}
