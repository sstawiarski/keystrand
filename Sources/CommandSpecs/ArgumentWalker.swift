import Foundation

/// Where a partially typed command stands relative to its argument tree.
public struct ArgumentWalkResult: Hashable, Sendable {
    /// Arguments that can receive the next token, including unused options, a repeatable argument and the next required argument.
    public var candidates: [CommandArgument]
    /// The innermost argument that must come next (nil when everything required is present).
    public var expected: CommandArgument?
    /// The block or one-of containing `expected`, or nil for the command itself.
    public var parent: CommandArgument?
    /// Index in the command's top-level `arguments` currently being filled (signature highlight).
    public var activeTopLevelIndex: Int?
    /// True when every required argument has been typed.
    public var isSatisfied: Bool

    public init(candidates: [CommandArgument] = [], expected: CommandArgument? = nil, parent: CommandArgument? = nil,
                activeTopLevelIndex: Int? = nil, isSatisfied: Bool = true) {
        self.candidates = candidates
        self.expected = expected
        self.parent = parent
        self.activeTopLevelIndex = activeTopLevelIndex
        self.isSatisfied = isSatisfied
    }

    /// Keywords (tokens) that could be typed next, in spec order, de-duplicated.
    public var keywordSuggestions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for candidate in candidates {
            for token in ArgumentWalker.leadingTokens(candidate) where seen.insert(token).inserted {
                out.append(token)
            }
        }

        return out
    }
}

/// Finds the next arguments from tokens excluding the command name.
/// Options can appear in any order; unknown words are skipped.
/// Counted arguments (`PREFIX count prefix ...`, `numkeys key ...`) consume exactly `count` values.
public enum ArgumentWalker {
    public static func walk(_ arguments: [CommandArgument], tokens: [String]) -> ArgumentWalkResult {
        let walker = Walker(tokens: tokens.map { $0.uppercased() })
        switch walker.parseList(arguments, from: 0, outer: [], parent: nil, depth: 0) {
        case .exhausted(let state):
            return state
        case .finished:
            return ArgumentWalkResult(isSatisfied: true)
        }
    }

    /// Uppercased keywords that start `argument` (its token; one-of children tokens; a block's first token).
    public static func leadingTokens(_ argument: CommandArgument) -> [String] {
        if let token = argument.token, !token.isEmpty { return [token.uppercased()] }
        switch argument.type {
        case .oneof:
            return argument.arguments.flatMap(leadingTokens)
        case .block:
            return argument.arguments.first.map(leadingTokens) ?? []
        default:
            return []
        }
    }

    static func isCountArgument(_ argument: CommandArgument) -> Bool {
        guard argument.type == .integer else { return false }
        return ["count", "nargs", "numkeys", "num", "numfields", "num_keys", "numsrc"].contains(argument.name.lowercased())
    }
}

private enum Outcome {
    case exhausted(ArgumentWalkResult)
    case finished(Int)
}

private struct Walker {
    let tokens: [String]

    func parseList(_ args: [CommandArgument], from start: Int, outer: Set<String>,
                            parent: CommandArgument?, depth: Int) -> Outcome {
        var pos = start
        var next = 0
        var used = Set<Int>()
        var repeatable: Int?
        var countedLeft: Int?
        let ownKeywords = Set(args.flatMap(ArgumentWalker.leadingTokens))
        let innerOuter = outer.union(ownKeywords)

        func requiredIndex() -> Int? {
            guard next < args.count else { return nil }
            return (next..<args.count).first { !args[$0].optional }
        }

        func expectation(merging inner: ArgumentWalkResult? = nil) -> ArgumentWalkResult {
            var candidates: [CommandArgument] = inner?.candidates ?? []
            var expected: CommandArgument?
            var topIndex: Int?
            if let r = repeatable, let left = countedLeft, left > 0 {
                expected = args[r]
                topIndex = r
                candidates.append(args[r])
                return ArgumentWalkResult(candidates: candidates, expected: expected, parent: parent,
                                          activeTopLevelIndex: depth == 0 ? topIndex : nil, isSatisfied: false)
            }

            for k in 0..<min(next, args.count) where !used.contains(k) && args[k].optional
                && !ArgumentWalker.leadingTokens(args[k]).isEmpty {
                candidates.append(args[k])
            }

            if let r = repeatable, countedLeft == nil, args[r].multiple { candidates.append(args[r]) }
            let required = requiredIndex()
            if next < args.count {
                let end = required ?? (args.count - 1)
                candidates.append(contentsOf: args[next...end])
            }

            if let required {
                expected = args[required]
                topIndex = required
            }

            return ArgumentWalkResult(candidates: candidates, expected: expected, parent: parent,
                                      activeTopLevelIndex: depth == 0 ? topIndex : nil, isSatisfied: required == nil)
        }

        func noteConsumed(_ k: Int, endingAt end: Int) {
            used.insert(k)
            if k >= next { next = k + 1 }
            repeatable = args[k].multiple ? k : nil
            if countedLeft != nil, repeatable == nil { countedLeft = nil }
            if ArgumentWalker.isCountArgument(args[k]), k + 1 < args.count, args[k + 1].multiple, end > 0 {
                let n = Int(tokens[end - 1]) ?? 0
                if n <= 0 {
                    used.insert(k + 1)
                    next = max(next, k + 2)
                } else {
                    countedLeft = n
                    repeatable = k + 1
                    next = max(next, k + 2)
                    used.insert(k + 1)
                }
            }
        }

        while true {
            if pos >= tokens.count {
                return .exhausted(expectation())
            }

            let word = tokens[pos]

            // Counted repetition (`PREFIX 2 a b`).
            if let r = repeatable, let left = countedLeft, left > 0 {
                switch parseArgument(args[r], at: pos, outer: innerOuter, depth: depth, index: r) {
                case .exhausted(let state): return .exhausted(state)
                case .finished(let end):
                    pos = max(end, pos + 1)
                    countedLeft = left - 1
                    if countedLeft == 0 { countedLeft = nil; repeatable = nil }
                }

                continue
            }

            // Matches unused earlier options, arguments through the next required argument, or a repeat.
            var keyed: [Int] = []
            for k in 0..<min(next, args.count) where !used.contains(k) && args[k].optional { keyed.append(k) }
            if let required = requiredIndex() {
                keyed.append(contentsOf: next...required)
            } else if next < args.count {
                keyed.append(contentsOf: next..<args.count)
            }

            if let r = repeatable, args[r].multiple { keyed.append(r) }
            if let k = keyed.first(where: { ArgumentWalker.leadingTokens(args[$0]).contains(word) }) {
                switch parseArgument(args[k], at: pos, outer: innerOuter, depth: depth, index: k) {
                case .exhausted(let state):
                    if state.isSatisfied {
                        noteConsumed(k, endingAt: tokens.count)
                        return .exhausted(merge(inner: state, outer: expectation()))
                    }

                    return .exhausted(state)
                case .finished(let end):
                    pos = max(end, pos + 1)
                    noteConsumed(k, endingAt: pos)
                }

                continue
            }

            let required = requiredIndex()
            if required == nil, outer.contains(word) { return .finished(pos) }

            if let j = required {
                let leading = ArgumentWalker.leadingTokens(args[j])
                if !leading.isEmpty, args[j].type != .oneof || !args[j].arguments.contains(where: { ArgumentWalker.leadingTokens($0).isEmpty }) {
                    if let r = repeatable, args[r].multiple, ArgumentWalker.leadingTokens(args[r]).isEmpty {
                        switch parseArgument(args[r], at: pos, outer: innerOuter, depth: depth, index: r) {
                        case .exhausted(let state): return .exhausted(state)
                        case .finished(let end): pos = max(end, pos + 1)
                        }

                        continue
                    }

                    if outer.contains(word) { return .finished(pos) }
                    pos += 1
                    continue
                }

                switch parseArgument(args[j], at: pos, outer: innerOuter, depth: depth, index: j) {
                case .exhausted(let state):
                    if state.isSatisfied {
                        noteConsumed(j, endingAt: tokens.count)
                        return .exhausted(merge(inner: state, outer: expectation()))
                    }

                    return .exhausted(state)
                case .finished(let end):
                    pos = max(end, pos + 1)
                    noteConsumed(j, endingAt: pos)
                }

                continue
            }

            if let r = repeatable, args[r].multiple, ArgumentWalker.leadingTokens(args[r]).isEmpty {
                switch parseArgument(args[r], at: pos, outer: innerOuter, depth: depth, index: r) {
                case .exhausted(let state): return .exhausted(state)
                case .finished(let end): pos = max(end, pos + 1)
                }

                continue
            }

            return .finished(pos)
        }
    }

    private func merge(inner: ArgumentWalkResult, outer: ArgumentWalkResult) -> ArgumentWalkResult {
        var merged = outer
        merged.candidates = inner.candidates + outer.candidates
        return merged
    }

    func parseArgument(_ arg: CommandArgument, at start: Int, outer: Set<String>, depth: Int,
                                index: Int) -> Outcome {
        var pos = start

        func topIndexed(_ state: ArgumentWalkResult) -> ArgumentWalkResult {
            var copy = state
            if depth == 0 { copy.activeTopLevelIndex = index }
            return copy
        }

        if let token = arg.token, !token.isEmpty {
            guard pos < tokens.count else {
                return .exhausted(topIndexed(ArgumentWalkResult(candidates: [arg], expected: arg, isSatisfied: false)))
            }
            if tokens[pos] == token.uppercased() {
                pos += 1
            } else if arg.type == .pureToken {
                return .finished(pos)
            }

            if arg.type == .pureToken { return .finished(pos) }
        }

        switch arg.type {
        case .pureToken:
            return .finished(pos < tokens.count ? pos + 1 : pos)
        case .oneof:
            guard pos < tokens.count else {
                return .exhausted(topIndexed(ArgumentWalkResult(candidates: arg.arguments, expected: arg, parent: arg,
                                                                isSatisfied: false)))
            }
            let word = tokens[pos]
            let child = arg.arguments.first { ArgumentWalker.leadingTokens($0).contains(word) }
                ?? arg.arguments.first { ArgumentWalker.leadingTokens($0).isEmpty }
            guard let child else { return .finished(pos) }
            switch parseArgument(child, at: pos, outer: outer, depth: depth + 1, index: index) {
            case .exhausted(let state): return .exhausted(topIndexed(state))
            case .finished(let end): return .finished(end)
            }
        case .block:
            switch parseList(arg.arguments, from: pos, outer: outer, parent: arg, depth: depth + 1) {
            case .exhausted(let state): return .exhausted(topIndexed(state))
            case .finished(let end): return .finished(end)
            }
        default:
            guard pos < tokens.count else {
                return .exhausted(topIndexed(ArgumentWalkResult(candidates: [arg], expected: arg, isSatisfied: false)))
            }
            return .finished(pos + 1)
        }
    }
}
