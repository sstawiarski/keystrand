import Foundation
import RedisUI
import SwiftUI

/// The license files bundled in the app's Resources folder.
struct Acknowledgements: Equatable, Sendable {
    struct License: Identifiable, Equatable, Sendable {
        /// The file's path relative to Resources, for example `LICENSES/RSALv2.txt`.
        let name: String
        let text: String

        var id: String { name }
    }

    static let noticesFile = "THIRD_PARTY_NOTICES.md"
    static let licenseFile = "LICENSE"
    static let licensesFolder = "LICENSES"

    var notices: String?
    var licenses: [License]

    /// Reads the notices, `LICENSE`, then `LICENSES/*.txt` by name; missing or unreadable files are left out.
    static func load(from resources: URL?) -> Acknowledgements {
        guard let resources else { return Acknowledgements(notices: nil, licenses: []) }

        func read(_ path: String) -> String? {
            try? String(contentsOf: resources.appending(path: path), encoding: .utf8)
        }

        let folder = resources.appending(path: licensesFolder, directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let paths = [licenseFile] + files.filter { $0.hasSuffix(".txt") }.sorted().map { "\(licensesFolder)/\($0)" }
        let licenses = paths.compactMap { path in read(path).map { License(name: path, text: $0) } }
        return Acknowledgements(notices: read(noticesFile), licenses: licenses)
    }
}

/// Help > Acknowledgements: the third-party notices, then each bundled license text.
public struct AcknowledgementsView: View {
    private let content: Acknowledgements

    public init() {
        self.init(resources: Bundle.main.resourceURL)
    }

    init(resources: URL?) {
        content = Acknowledgements.load(from: resources)
    }

    public var body: some View {
        if content.notices == nil, content.licenses.isEmpty {
            unavailable
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notices = content.notices {
                        MarkdownView(markdown: notices)
                    } else {
                        unavailable
                    }

                    if !content.licenses.isEmpty {
                        Divider()
                        Text("License Texts")
                            .font(.title3.weight(.semibold))
                        ForEach(content.licenses) { license in
                            DisclosureGroup(license.name) {
                                Text(license.text)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("Notices Unavailable", systemImage: "doc.questionmark",
                               description: Text("\(Acknowledgements.noticesFile) isn't in the app bundle."))
    }
}
