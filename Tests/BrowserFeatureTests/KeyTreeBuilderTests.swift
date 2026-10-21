import Foundation
@testable import BrowserFeature
import RedisCore
import Testing

struct KeyTreeBuilderTests {
    private func inputs(_ names: [String]) -> [KeyTreeInput] {
        names.map { KeyTreeInput(name: Data($0.utf8), display: $0) }
    }

    @Test func splitsOnSingleDelimiter() {
        #expect(KeyTreeBuilder.split("a:b:c", delimiters: [":"], prefixLength: 0) == ["a", "b", "c"])
        #expect(KeyTreeBuilder.split("plain", delimiters: [":"], prefixLength: 0) == ["plain"])
        #expect(KeyTreeBuilder.split("a::b", delimiters: [":"], prefixLength: 0) == ["a", "", "b"])
        #expect(KeyTreeBuilder.split(":a", delimiters: [":"], prefixLength: 0) == ["", "a"])
    }

    @Test func splitsOnSeveralDelimiters() {
        #expect(KeyTreeBuilder.split("a:b-c", delimiters: [":", "-"], prefixLength: 0) == ["a", "b", "c"])
        #expect(KeyTreeBuilder.split("a::b", delimiters: ["::"], prefixLength: 0) == ["a", "b"])
    }

    @Test func ignoresSeparatorsInPrefix() {
        #expect(KeyTreeBuilder.split("ab:cd:ef", delimiters: [":"], prefixLength: 4) == ["ab:cd", "ef"])
        #expect(KeyTreeBuilder.split("ab:cd", delimiters: [":"], prefixLength: 100) == ["ab:cd"])
    }

    @Test func keepsHashTagTogether() {
        #expect(KeyTreeBuilder.split("{user:1}:name", delimiters: [":"], prefixLength: 0) == ["{user:1}", "name"])
        #expect(KeyTreeBuilder.split("a:{b:c}:d", delimiters: [":"], prefixLength: 0) == ["a", "{b:c}", "d"])
        #expect(KeyTreeBuilder.split("a:{}:d", delimiters: [":"], prefixLength: 0) == ["a", "{}", "d"])
    }

    @Test func buildsFoldersBeforeKeysWithCounts() {
        let roots = KeyTreeBuilder.build(inputs(["user:1", "user:2", "order:1", "zeta", "alpha"]),
                                         options: KeyTreeOptions())
        #expect(roots.map(\.name) == ["order", "user", "alpha", "zeta"])
        let user = roots[1]
        #expect(!user.isLeaf)
        #expect(user.keyCount == 2)
        #expect(user.percentage == 40)
        #expect(user.fullName == "user")
        #expect(user.children.map(\.name) == ["1", "2"])
        #expect(user.children[0].fullName == "user:1")
        #expect(user.children[0].keyName == Data("user:1".utf8))
        #expect(roots[2].isLeaf)
    }

    @Test func sortsDescending() {
        let roots = KeyTreeBuilder.build(inputs(["a:1", "b:1", "x", "y"]),
                                         options: KeyTreeOptions(sort: .desc))
        #expect(roots.map(\.name) == ["b", "a", "y", "x"])
    }

    @Test func folderAndLeafWithSameName() {
        let roots = KeyTreeBuilder.build(inputs(["a", "a:b"]), options: KeyTreeOptions())
        #expect(roots.count == 2)
        #expect(!roots[0].isLeaf)
        #expect(roots[1].isLeaf)
    }

    @Test func flattenRespectsExpandedFolders() {
        let roots = KeyTreeBuilder.build(inputs(["a:b:1", "a:b:2", "c"]), options: KeyTreeOptions())
        #expect(KeyTreeBuilder.flatten(roots, expanded: []).count == 2)
        let aPath = "a"
        let abPath = "a" + KeyTreeBuilder.pathSeparator + "b"
        let rows = KeyTreeBuilder.flatten(roots, expanded: [aPath, abPath])
        #expect(rows.map(\.node.name) == ["a", "b", "1", "2", "c"])
        #expect(rows.map(\.depth) == [0, 1, 2, 2, 0])
        #expect(rows[0].isExpanded)
    }

    @Test func singleChildChainAndParents() {
        let roots = KeyTreeBuilder.build(inputs(["a:b:c:1", "a:b:c:2"]), options: KeyTreeOptions())
        let sep = KeyTreeBuilder.pathSeparator
        #expect(KeyTreeBuilder.singleChildChain(from: roots[0]) == ["a", "a\(sep)b", "a\(sep)b\(sep)c"])
        #expect(KeyTreeBuilder.parentFolderPaths(of: "a:b:c:1", options: KeyTreeOptions())
            == ["a", "a\(sep)b", "a\(sep)b\(sep)c"])
        #expect(KeyTreeBuilder.find(.folder("a\(sep)b"), in: roots)?.name == "b")
        #expect(KeyTreeBuilder.find(.leaf(Data("a:b:c:2".utf8)), in: roots)?.name == "2")
    }

    @Test func multipleDelimitersUseDashInFullName() {
        let options = KeyTreeOptions(delimiters: [":", "-"])
        let roots = KeyTreeBuilder.build(inputs(["a:b-1"]), options: options)
        #expect(roots[0].children[0].fullName == "a-b")
        #expect(options.delimiterView == "-")
    }

    @Test func nonPrintableKeysMarkFolders() {
        let bad = Data([0x61, 0x3A, 0xFF, 0xFE])
        let key = RedisKeyName(bad)
        let roots = KeyTreeBuilder.build([KeyTreeInput(name: bad, display: key.displayString(format: .unicode),
                                                       isPrintable: key.isPrintable)], options: KeyTreeOptions())
        #expect(roots.count == 1)
        #expect(!roots[0].isPrintable)
        #expect(roots[0].children.first?.keyName == bad)
    }

    @Test func buildsLargeTreeQuickly() {
        let names = (0..<20_000).map { "tenant:\($0 % 50):user:\($0)" }
        let start = Date()
        let roots = KeyTreeBuilder.build(inputs(names), options: KeyTreeOptions())
        #expect(roots.count == 1)
        #expect(roots[0].keyCount == 20_000)
        #expect(roots[0].children.count == 50)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func deepKeyIsCappedAndBuildsOnDetachedTask() async {
        let display = String(repeating: "a:", count: 10_000) + "x"
        let options = KeyTreeOptions()
        let input = KeyTreeInput(name: Data(display.utf8), display: display)
        let roots = await Task.detached { KeyTreeBuilder.build([input], options: options) }.value
        var depth = 0
        var node = roots.first
        var paths = Set<String>()
        while let current = node, !current.isLeaf {
            depth += 1
            if let path = current.folderPath { paths.insert(path) }
            node = current.children.first
        }

        #expect(depth == KeyTreeBuilder.maxFolderDepth)
        let leaf = node
        #expect(leaf?.keyName == input.name)
        #expect(leaf?.fullName == display)
        #expect(leaf?.name == String(repeating: "a:", count: 10_000 - KeyTreeBuilder.maxFolderDepth) + "x")
        let parents = KeyTreeBuilder.parentFolderPaths(of: display, options: options)
        #expect(parents.count == KeyTreeBuilder.maxFolderDepth)
        #expect(Set(parents) == paths)
        let rows = KeyTreeBuilder.flatten(roots, expanded: paths)
        #expect(rows.count == KeyTreeBuilder.maxFolderDepth + 1)
        #expect(rows.last?.node.keyName == input.name)
    }

    @Test func shallowKeysAreNotCapped() {
        let parts = KeyTreeBuilder.segments("a:b:c", options: KeyTreeOptions())
        #expect(parts == ["a", "b", "c"])
    }
}
