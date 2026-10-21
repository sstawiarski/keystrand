import Foundation

public struct CompletionItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case command, subcommand, keyword, index, field, function
    }

    public var kind: Kind
    public var label: String
    /// Replaces the word before the caret; may contain snippet placeholders (`${1:tag}`).
    public var insertText: String
    public var detail: String?
    /// Markdown.
    public var documentation: String?

    public var id: String { "\(kind.rawValue):\(label)" }

    public init(kind: Kind, label: String, insertText: String? = nil, detail: String? = nil, documentation: String? = nil) {
        self.kind = kind
        self.label = label
        self.insertText = insertText ?? label
        self.detail = detail
        self.documentation = documentation
    }
}

/// Parameter hint with full syntax and the current argument’s UTF-16 range.
public struct SignatureHint: Hashable, Sendable {
    public var label: String
    public var highlight: NSRange?
    public var documentation: String?

    public init(label: String, highlight: NSRange? = nil, documentation: String? = nil) {
        self.label = label
        self.highlight = highlight
        self.documentation = documentation
    }
}

/// A RediSearch attribute offered after `@` inside FT queries.
public struct SearchFieldSuggestion: Hashable, Sendable {
    public var name: String
    /// `TAG`, `TEXT`, `NUMERIC`, `GEO`, `VECTOR`, ... (any case).
    public var type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

/// Live data the editor can pass in (index names from `FT._LIST`, attributes from `FT.INFO`, loaded modules).
public struct CompletionContext: Hashable, Sendable {
    public var indexes: [String]
    public var fields: [SearchFieldSuggestion]
    /// Commands to offer.
    public var availability: CommandAvailability

    public init(indexes: [String] = [], fields: [SearchFieldSuggestion] = [],
                availability: CommandAvailability = .unrestricted) {
        self.indexes = indexes
        self.fields = fields
        self.availability = availability
    }
}

public struct CompletionResult: Hashable, Sendable {
    public var items: [CompletionItem]
    public var signature: SignatureHint?
    public var command: CommandSpec?
    public var walk: ArgumentWalkResult?
    /// The word being typed (possibly empty).
    public var currentWord: String
    public var isInsideQuotes: Bool
    /// The command expects an index name and the context has none ("No indexes to display").
    public var needsIndexes: Bool

    public init(items: [CompletionItem] = [], signature: SignatureHint? = nil, command: CommandSpec? = nil,
                walk: ArgumentWalkResult? = nil, currentWord: String = "", isInsideQuotes: Bool = false,
                needsIndexes: Bool = false) {
        self.items = items
        self.signature = signature
        self.command = command
        self.walk = walk
        self.currentWord = currentWord
        self.isInsideQuotes = isInsideQuotes
        self.needsIndexes = needsIndexes
    }
}

/// Completes commands, keywords, RediSearch indexes, `@field` templates and APPLY/FILTER functions. Provides signature hints.
public struct CompletionEngine: Sendable {
    public let catalog: CommandCatalog

    /// RediSearch expression functions offered inside APPLY / FILTER expressions.
    public static let expressionFunctions = [
        "exists", "log", "abs", "ceil", "floor", "log2", "exp", "sqrt", "upper", "lower", "startswith", "contains",
        "strlen", "substr", "format", "matched_terms", "split", "timefmt", "parsetime", "day", "hour", "minute",
        "month", "dayofweek", "dayofmonth", "dayofyear", "year", "monthofyear", "geodistance",
    ]

    public init(catalog: CommandCatalog = .shared) {
        self.catalog = catalog
    }

    /// `cursorOffset` is a UTF-16 offset into `text`.
    public func complete(text: String, cursorOffset: Int, context: CompletionContext = CompletionContext()) -> CompletionResult {
        guard let query = Self.commandText(in: text, cursorOffset: cursorOffset) else { return CompletionResult() }
        let line = CommandLineTokenizer.tokenize(query)
        var complete = line.tokens
        var current: CommandLineToken?
        if !line.endsWithSeparator, let last = complete.last {
            current = last
            complete.removeLast()
        }

        let currentWord = current?.text ?? ""
        let insideQuotes = current.map { $0.isQuoted && !$0.isTerminated } ?? false

        var words = complete.map(\.text)
        if let first = words.first, Int(first) != nil { words.removeFirst() }

        if words.isEmpty {
            if insideQuotes { return CompletionResult(currentWord: currentWord, isInsideQuotes: true) }
            return CompletionResult(items: commandItems(prefix: currentWord, availability: context.availability),
                                    currentWord: currentWord)
        }

        guard let spec = matchCommand(words) else {
            return CompletionResult(currentWord: currentWord, isInsideQuotes: insideQuotes)
        }
        let nameWords = catalog.wordCount(of: spec)

        if nameWords == 1, words.count == 1, catalog.isContainer(spec.name) {
            let subs = catalog.subcommands(of: spec.name).compactMap { sub -> CompletionItem? in
                guard let word = sub.name.split(separator: " ").last.map(String.init),
                      word.hasPrefix(currentWord.uppercased()) else { return nil }
                return CompletionItem(kind: .subcommand, label: word, insertText: word + " ",
                                      detail: CommandSyntax.argumentsLine(sub), documentation: sub.summary)
            }
            return CompletionResult(items: subs, command: spec, currentWord: currentWord, isInsideQuotes: insideQuotes)
        }

        let typedArgs = Array(words.dropFirst(nameWords))
        let walk = ArgumentWalker.walk(spec.arguments, tokens: typedArgs)
        let signature = Self.signature(for: spec, activeIndex: walk.activeTopLevelIndex)
        var result = CompletionResult(signature: signature, command: spec, walk: walk, currentWord: currentWord,
                                      isInsideQuotes: insideQuotes)

        let expectedName = walk.expected?.name.lowercased()
        let isSearch = spec.name.hasPrefix("FT.")

        if let fieldPrefix = Self.fieldPrefix(current: current), !context.fields.isEmpty {
            result.items = fieldItems(prefix: fieldPrefix, fields: context.fields, inQuery: insideQuotes)
            return result
        }

        if insideQuotes {
            if walk.expected?.expression == true || Self.isExpressionArgument(walk) {
                result.items = functionItems(prefix: Self.lastWord(currentWord))
            }

            return result
        }

        if isSearch, expectedName == "index", spec.name != "FT.CREATE" {
            if context.indexes.isEmpty {
                result.needsIndexes = true
            } else {
                result.items = indexItems(prefix: currentWord, indexes: context.indexes, spec: spec)
            }

            return result
        }

        if expectedName == "query" { return result }

        let prefix = currentWord.uppercased()
        var items: [CompletionItem] = []
        var seen = Set<String>()
        for candidate in walk.candidates {
            for token in ArgumentWalker.leadingTokens(candidate) where token.hasPrefix(prefix) && seen.insert(token).inserted {
                let source = Self.argument(startingWith: token, in: candidate) ?? candidate
                let insert = source.type == .pureToken ? token : token + " "
                items.append(CompletionItem(kind: .keyword, label: token, insertText: insert,
                                            detail: CommandSyntax.syntax(source), documentation: source.summary))
            }
        }

        result.items = items
        return result
    }

    /// Signature hint only.
    public func signature(text: String, cursorOffset: Int) -> SignatureHint? {
        complete(text: text, cursorOffset: cursorOffset).signature
    }

    // MARK: - Items

    func commandItems(prefix: String, availability: CommandAvailability) -> [CompletionItem] {
        let upper = prefix.uppercased()
        let matches = catalog.available(availability).filter {
            $0.name.hasPrefix(upper) && !CommandGroups.isDeprecatedCommand($0)
        }
        return catalog.completionOrder(matches).map { spec in
            CompletionItem(kind: .command, label: spec.name, insertText: spec.name + " ",
                           detail: CommandSyntax.argumentsLine(spec),
                           documentation: CommandSyntax.markdownDocumentation(spec))
        }
    }

    func indexItems(prefix: String, indexes: [String], spec: CommandSpec) -> [CompletionItem] {
        let takesQuery = spec.arguments.dropFirst().first?.name.lowercased() == "query"
        return indexes.filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix.lowercased()) }.map { index in
            let quoted = "'\(index.replacingOccurrences(of: "'", with: "\\'"))'"
            let insert = takesQuery ? "\(quoted) '${1:query to search}'" : quoted + " "
            return CompletionItem(kind: .index, label: index, insertText: insert, detail: "Index")
        }
    }

    func fieldItems(prefix: String, fields: [SearchFieldSuggestion], inQuery: Bool) -> [CompletionItem] {
        fields.filter { prefix.isEmpty || $0.name.lowercased().hasPrefix(prefix.lowercased()) }.map { field in
            CompletionItem(kind: .field, label: "@\(field.name)",
                           insertText: inQuery ? Self.fieldTemplate(field) : "@\(field.name)",
                           detail: field.type.uppercased())
        }
    }

    func functionItems(prefix: String) -> [CompletionItem] {
        Self.expressionFunctions.filter { prefix.isEmpty || $0.hasPrefix(prefix.lowercased()) }.map { name in
            CompletionItem(kind: .function, label: name, insertText: "\(name)(${1:arg})", detail: "Function")
        }
    }

    /// `@f:{${1:tag}}` for TAG, `@f:(${1:term})` for TEXT, numeric/geo ranges, `@f $${1:vector}` for VECTOR.
    public static func fieldTemplate(_ field: SearchFieldSuggestion) -> String {
        let name = field.name
        switch field.type.uppercased() {
        case "TAG": return "@\(name):{${1:tag}}"
        case "TEXT": return "@\(name):(${1:term})"
        case "NUMERIC": return "@\(name):[${1:range}]"
        case "GEO": return "@\(name):[${1:lon} ${2:lat} ${3:radius} ${4:unit}]"
        case "VECTOR": return "@\(name) $${1:vector}"
        default: return "@\(name)"
        }
    }

    // MARK: - Helpers

    func matchCommand(_ words: [String]) -> CommandSpec? {
        guard let first = words.first else { return nil }
        if words.count > 1, let two = catalog.spec(named: "\(first) \(words[1])") { return two }
        return catalog.spec(named: first)
    }

    /// Signature label (`SET key value [NX | XX] ...`) with the active top-level argument highlighted.
    public static func signature(for spec: CommandSpec, activeIndex: Int?) -> SignatureHint {
        var label = spec.name
        var highlight: NSRange?
        for (index, argument) in spec.arguments.enumerated() {
            let text = CommandSyntax.syntax(argument)
            guard !text.isEmpty else { continue }
            label += " "
            let start = (label as NSString).length
            label += text
            if index == activeIndex { highlight = NSRange(location: start, length: (text as NSString).length) }
        }

        return SignatureHint(label: label, highlight: highlight, documentation: spec.summary)
    }

    /// Returns the command through the caret, including lines with leading whitespace.
    /// Skips `//` comment lines and removes a `[...]` params prefix from the first line.
    /// Returns nil if the caret is on a comment line.
    public static func commandText(in text: String, cursorOffset: Int) -> String? {
        let ns = text as NSString
        let caret = max(0, min(cursorOffset, ns.length))
        let before = ns.substring(to: caret)
        var lines = before.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var collected: [String] = []
        while let line = lines.popLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") {
                if collected.isEmpty { return nil }
                continue
            }

            collected.insert(line, at: 0)
            if let first = line.first, !first.isWhitespace { break }
        }

        var command = collected.joined(separator: " ")
        if lines.isEmpty, command.hasPrefix("["), let close = command.firstIndex(of: "]") {
            command = String(command[command.index(after: close)...])
        }

        return command
    }

    static func fieldPrefix(current: CommandLineToken?) -> String? {
        guard let current else { return nil }
        let word = lastWord(current.text)
        guard word.hasPrefix("@") else { return nil }
        let name = word.dropFirst()
        guard !name.contains(":") else { return nil }
        return String(name)
    }

    static func lastWord(_ text: String) -> String {
        let stops = CharacterSet(charactersIn: " \t()|,{}[]")
        guard let range = text.rangeOfCharacter(from: stops, options: .backwards) else { return text }
        return String(text[range.upperBound...])
    }

    static func isExpressionArgument(_ walk: ArgumentWalkResult) -> Bool {
        walk.parent?.expression == true || walk.candidates.contains { $0.expression && $0.token == nil }
    }

    static func argument(startingWith token: String, in candidate: CommandArgument) -> CommandArgument? {
        if candidate.token?.uppercased() == token { return candidate }
        switch candidate.type {
        case .oneof: return candidate.arguments.lazy.compactMap { argument(startingWith: token, in: $0) }.first
        case .block: return candidate.arguments.first.flatMap { argument(startingWith: token, in: $0) }.map { _ in candidate }
        default: return nil
        }
    }
}

/// CLI Tab completion cycles through case-insensitive command prefixes in alphabetical order.
/// Each cycle starts with the original text. Shift+Tab cycles backwards.
public struct CommandLineCompleter: Sendable {
    public let catalog: CommandCatalog
    /// Commands the server can run; the next new cycle uses it.
    public var availability: CommandAvailability
    private var cycle: [String] = []
    private var position = 0

    public init(catalog: CommandCatalog = .shared, availability: CommandAvailability = .unrestricted) {
        self.catalog = catalog
        self.availability = availability
    }

    /// Returns the replacement input for one Tab press.
    public mutating func complete(_ input: String, backwards: Bool = false) -> String {
        if cycle.isEmpty || cycle[position] != input {
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return input }
            let normalized = trimmed.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                + (input.last?.isWhitespace == true ? " " : "")
            let matches = catalog.sortedNames.filter {
                $0.hasPrefix(normalized) && !($0.hasPrefix("GRAPH."))
                    && (catalog.commands[$0].map(availability.includes) ?? true)
            }
            guard !matches.isEmpty else { return input }
            cycle = [input] + matches
            position = 0
        }

        position = backwards ? (position - 1 + cycle.count) % cycle.count : (position + 1) % cycle.count
        return cycle[position]
    }

    /// Call when the user edits the input by typing.
    public mutating func reset() {
        cycle = []
        position = 0
    }
}

/// CLI inline hint for argument syntax remaining after the command (`key [key ...]`).
public struct ArgumentHint: Hashable, Sendable {
    public var command: CommandSpec
    /// Remaining arguments (dimmed after the input).
    public var untyped: String
    /// Every argument of the command.
    public var full: String
}

public enum ArgumentHintCalculator {
    public static func hint(for input: String, catalog: CommandCatalog = .shared) -> ArgumentHint? {
        guard let spec = catalog.match(line: input) else { return nil }
        let names = CommandSyntax.argumentNames(spec.arguments)
        guard !names.isEmpty else { return nil }
        let typed = CommandLineTokenizer.wordCount(input)
        let commandWords = catalog.wordCount(of: spec)
        guard typed >= commandWords else { return nil }
        let firstOptional = names.firstIndex { $0.contains("[") }
        var start = typed - commandWords
        if let firstOptional, start >= firstOptional { start = firstOptional }
        start = max(0, min(start, names.count))
        let untyped = names[start...].joined(separator: " ")
        guard !untyped.isEmpty else { return nil }
        return ArgumentHint(command: spec, untyped: untyped, full: names.joined(separator: " "))
    }
}
