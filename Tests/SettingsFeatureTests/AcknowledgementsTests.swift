import Foundation
@testable import SettingsFeature
import Testing

struct AcknowledgementsTests {
    private func makeResources(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ack-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        return root
    }

    @Test func loadsNoticesThenLicenseThenSortedLicenseTexts() throws {
        let root = try makeResources([
            "THIRD_PARTY_NOTICES.md": "# Third-Party Notices",
            "LICENSE": "MIT License",
            "LICENSES/RSALv2.txt": "RSALv2",
            "LICENSES/BSD-3-Clause-Redis.txt": "BSD",
            "LICENSES/notes.md": "ignored",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let content = Acknowledgements.load(from: root)
        #expect(content.notices == "# Third-Party Notices")
        #expect(content.licenses.map(\.name) == ["LICENSE", "LICENSES/BSD-3-Clause-Redis.txt", "LICENSES/RSALv2.txt"])
        #expect(content.licenses.last?.text == "RSALv2")
    }

    @Test func missingFilesAreLeftOut() throws {
        let root = try makeResources(["LICENSES/RSALv2.txt": "RSALv2"])
        defer { try? FileManager.default.removeItem(at: root) }

        let content = Acknowledgements.load(from: root)
        #expect(content.notices == nil)
        #expect(content.licenses.map(\.name) == ["LICENSES/RSALv2.txt"])
        #expect(Acknowledgements.load(from: nil) == Acknowledgements(notices: nil, licenses: []))
        #expect(Acknowledgements.load(from: root.appending(path: "missing")).licenses.isEmpty)
    }

    @Test func repositoryNoticesNameEveryLicenseFile() throws {
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = Acknowledgements.load(from: repo)
        let notices = try #require(content.notices)
        let texts = content.licenses.map(\.name).filter { $0.hasPrefix("LICENSES/") }
        #expect(texts.count >= 4)
        for name in texts {
            #expect(notices.contains(name), "THIRD_PARTY_NOTICES.md does not mention \(name)")
        }
    }
}
