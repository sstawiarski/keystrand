import Foundation
import RedisCore
import RedisUI
import TestSupport
import Testing
@testable import WorkbenchFeature

/// Checks every bundled tutorial page: files, titles, code blocks, links, cleanup, and module notes.
@MainActor
struct TutorialContentTests {
    private let library: TutorialLibrary

    init() throws {
        library = try TutorialLibrary.bundled()
    }

    private func blocks(of page: TutorialNode) throws -> [MarkdownBlock] {
        MarkdownParser.parse(try library.markdown(for: page))
    }

    private func codeBlocks(of page: TutorialNode) throws -> [MarkdownCodeBlock] {
        try blocks(of: page).compactMap { block in
            if case .code(let code) = block { return code }
            return nil
        }
    }

    @Test func manifestIDsAndPathsAreUnique() {
        var ids: [String] = []

        func walk(_ node: TutorialNode) {
            ids.append(node.id)
            for child in node.children ?? [] { walk(child) }
        }

        walk(library.root)
        #expect(Set(ids).count == ids.count)
        let paths = library.allPages.compactMap(\.args?.path)
        #expect(paths.count == library.allPages.count)
        #expect(Set(paths).count == paths.count)
    }

    @Test func idsUsedByOtherFeaturesExist() {
        for id in ["ds-strings", "ds-hashes", "ds-json-intro", "ds-ts-intro", "ds-prob-intro", "sq-intro", "vss-intro"] {
            #expect(library.node(id: id)?.isPage == true, "missing tutorial \(id)")
        }

        for button in WorkbenchEmptyState.tutorials {
            #expect(library.node(id: button.id)?.isPage == true, "missing tutorial \(button.id)")
        }
    }

    @Test func everyManifestPathIsABundledFile() throws {
        for page in library.allPages {
            let url = try #require(library.fileURL(for: page))
            #expect(FileManager.default.fileExists(atPath: url.path), "\(page.id): \(url.path)")
            #expect(try !library.markdown(for: page).isEmpty)
        }
    }

    @Test func everyBundledPageIsInTheManifest() throws {
        let base = library.baseURL.standardizedFileURL.path
        let enumerator = try #require(FileManager.default.enumerator(atPath: base))
        let files = Set(enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".md") }.map { "/" + $0 })
        let paths = Set(library.allPages.compactMap(\.args?.path))
        #expect(files == paths)
    }

    @Test func pagesOpenWithTheirLabelAsTitle() throws {
        for page in library.allPages {
            #expect(try blocks(of: page).first == .heading(level: 1, text: page.label), "\(page.id)")
        }

        let parsed = MarkdownParser.parse("# Title\n\nBody")
        #expect(TutorialsViewModel.droppingTitle(parsed) == [.paragraph("Body")])
        #expect(TutorialsViewModel.droppingTitle([.paragraph("Body")]) == [.paragraph("Body")])
    }

    @Test func everyCodeBlockIsARunnableRedisScript() throws {
        for page in library.allPages {
            let code = try codeBlocks(of: page)
            #expect(code.count >= 3, "\(page.id) has too few code blocks")
            for block in code {
                let fence = try #require(TutorialFence.parse(info: block.info), "\(page.id): \(block.info)")
                #expect(fence.isExecutable)
                #expect(!fence.label.isEmpty, "\(page.id): unlabeled block")
                let commands = try WorkbenchScriptParser.parse(block.code)
                #expect(!commands.isEmpty, "\(page.id): \(fence.label)")
                for command in commands {
                    let arguments = try #require(WorkbenchScriptParser.arguments(of: command), "\(page.id): \(command)")
                    let verb = arguments.first?.uppercased() ?? ""
                    #expect(verb != "FLUSHDB" && verb != "FLUSHALL", "\(page.id): \(command)")
                    #expect(WorkbenchScriptParser.invalidRepeatMessage(command) == nil, "\(page.id): \(command)")
                }
            }
        }
    }

    @Test func everyPageEndsWithACleanupBlock() throws {
        for page in library.allPages {
            let block = try #require(try codeBlocks(of: page).last)
            let fence = try #require(TutorialFence.parse(info: block.info))
            #expect(fence.runConfirmation, "\(page.id): cleanup must ask before it runs")
            let commands = try WorkbenchScriptParser.parse(block.code)
            #expect(commands.contains { $0.hasPrefix("UNLINK ") }, "\(page.id)")
            for command in commands {
                let arguments = try #require(WorkbenchScriptParser.arguments(of: command))
                #expect(["UNLINK", "DEL", "FT.DROPINDEX"].contains(arguments[0].uppercased()), "\(page.id): \(command)")
                #expect(arguments.dropFirst().allSatisfy { $0.contains("tutorial:") }, "\(page.id): \(command)")
            }
        }
    }

    @Test func linksPointToPagesOrRedisDocs() throws {
        let pattern = /\]\(([^)\s]+)\)/
        for page in library.allPages {
            let markdown = try library.markdown(for: page)
            #expect(!markdown.contains("utm_"), "\(page.id)")
            for match in markdown.matches(of: pattern) {
                let target = String(match.output.1)
                if target.hasPrefix("https://") {
                    #expect(target.hasPrefix("https://redis.io/docs/"), "\(page.id): \(target)")
                } else {
                    let url = try #require(URL(string: target))
                    #expect(library.page(linkedFrom: url, on: page) != nil, "\(page.id): \(target)")
                }
            }
        }
    }

    /// Without modules, a page that needs one must open with a note that says so, and Run reports it.
    @Test func modulePagesDeclareTheirRequirement() throws {
        let model = TutorialsViewModel(session: RedisTestServer.mockSession())
        let expected: [String: Set<CommandModuleRequirement>] = [
            "ds-json-intro": [.json],
            "ds-ts-intro": [.timeSeries],
            "ds-prob-intro": [.bloomFilter, .probabilistic],
            "sq-intro": [.search],
            "sq-aggregations": [.search],
            "vss-intro": [.search],
        ]
        for page in library.allPages {
            var missing: Set<CommandModuleRequirement> = []
            for block in try codeBlocks(of: page) {
                let fence = try #require(TutorialFence.parse(info: block.info))
                if case .moduleMissing(let requirement) = model.check(code: block.code, fence: fence) {
                    missing.insert(requirement)
                }
            }

            #expect(missing == expected[page.id, default: []], "\(page.id)")
            guard !missing.isEmpty else { continue }
            let body = TutorialsViewModel.droppingTitle(try blocks(of: page))
            guard case .quote(let note)? = body.first, case .paragraph(let text)? = note.first else {
                Issue.record("\(page.id) must open with a module note")
                continue
            }
            #expect(text.localizedCaseInsensitiveContains("require"), "\(page.id)")
        }
    }
}

/// Runs every bundled tutorial against Redis 8 (DB 0, keys renamed under a unique prefix) and checks that each
/// command succeeds and that the cleanup blocks leave nothing behind.
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis, modules: .search, .json, .timeSeries, .bloom, .vectorSet))
struct TutorialContentLiveTests {
    @Test func everyPageRunsAndCleansUp() async throws {
        let prefix = RedisTestServer.uniquePrefix("wbtutorials")
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.search)
        try #require(session.capabilities.hasSearch)
        let library = try TutorialLibrary.bundled()
        var indexes: Set<String> = []
        var ran = 0
        defer {
            Task { [indexes] in
                for index in indexes { _ = try? await session.execute(["FT.DROPINDEX", .string(index)]) }
                await removeKeys(db: RedisTestServer.DB.search, prefix: prefix)
            }
        }

        for page in library.allPages {
            for case .code(let block) in MarkdownParser.parse(try library.markdown(for: page)) {
                let script = block.code.replacingOccurrences(of: "tutorial:", with: "\(prefix)tutorial:")
                for command in try WorkbenchScriptParser.parse(script) {
                    let arguments = try CommandLineSplitter.split(WorkbenchScriptParser.multilineToOneLine(command))
                    if String(decoding: arguments[0], as: UTF8.self).uppercased() == "FT.CREATE" {
                        indexes.insert(String(decoding: arguments[1], as: UTF8.self))
                    }

                    ran += 1
                    do {
                        _ = try await session.execute(arguments)
                    } catch {
                        Issue.record("\(page.id): \(command): \(error.localizedDescription)")
                    }
                }
            }
        }

        let left = try await session.execute(["KEYS", .string("\(prefix)*")])
        #expect(left.arrayValue?.isEmpty == true, "keys left behind: \(left)")
        let list = try await session.execute(["FT._LIST"])
        let names = (list.arrayValue ?? []).compactMap(\.dataValue).map { String(decoding: $0, as: UTF8.self) }
        #expect(!names.contains { $0.contains(prefix) })
        #expect(indexes.count == 3)
        #expect(ran > 200)
    }
}
