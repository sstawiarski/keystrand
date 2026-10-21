import Foundation

/// Read-only Python pickle decoder (protocols 0-5) to `JSONValue`.
///
/// None/bool/int/float/str/bytes/list/tuple/dict/set/frozenset map to JSON. `datetime`, `date`, `Decimal`,
/// `OrderedDict`, `set` reducers are recognised; other globals become `{"__class__", "args", "state"}`.
enum Pickle {
    struct DecodeError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    /// Reference type so memoised containers mutated later (APPENDS/SETITEMS/BUILD) stay shared.
    final class Obj {
        enum Kind {
            case none, bool(Bool), int(String), float(Double), str(String), bytes([UInt8])
            case list([Obj]), tuple([Obj]), dict([(Obj, Obj)]), set([Obj])
            case global(String, String)
            case instance(cls: String, args: [Obj], state: Obj?, items: [(Obj, Obj)], listItems: [Obj])
            case mark
        }

        var kind: Kind
        init(_ kind: Kind) { self.kind = kind }
    }

    static func decode(_ bytes: [UInt8]) throws -> JSONValue {
        var machine = Machine(reader: ByteReader(bytes))
        let result = try machine.run()
        return json(result, depth: 0)
    }

    struct Machine {
        var reader: ByteReader
        var stack: [Obj] = []
        var metastack: [[Obj]] = []
        var memo: [Int: Obj] = [:]

        mutating func pop() throws -> Obj {
            guard let top = stack.popLast() else { throw DecodeError("stack underflow") }
            return top
        }

        mutating func top() throws -> Obj {
            guard let top = stack.last else { throw DecodeError("stack underflow") }
            return top
        }

        mutating func popMark() throws -> [Obj] {
            let items = stack
            guard let previous = metastack.popLast() else { throw DecodeError("mark not found") }
            stack = previous
            return items
        }

        mutating func textLine() throws -> String {
            var line = try reader.line()
            if line.last == 0x0D { line.removeLast() }
            return String(decoding: line, as: UTF8.self)
        }

        mutating func run() throws -> Obj {
            var steps = 0
            while true {
                steps += 1
                if steps > 10_000_000 { throw DecodeError("pickle too large") }
                let op = try reader.u8()
                switch op {
                case 0x80: _ = try reader.u8() // PROTO
                case 0x95: try reader.skip(8) // FRAME
                case UInt8(ascii: "."): // STOP
                    return try pop()
                case UInt8(ascii: "("): // MARK
                    metastack.append(stack)
                    stack = []
                case UInt8(ascii: "N"): stack.append(Obj(.none))
                case 0x88: stack.append(Obj(.bool(true)))
                case 0x89: stack.append(Obj(.bool(false)))
                case UInt8(ascii: "I"):
                    let text = try textLine()
                    switch text {
                    case "01": stack.append(Obj(.bool(true)))
                    case "00": stack.append(Obj(.bool(false)))
                    default:
                        guard let v = Int64(text) else { throw DecodeError("invalid INT \(text)") }
                        stack.append(Obj(.int(String(v))))
                    }
                case UInt8(ascii: "J"): stack.append(Obj(.int(String(Int32(bitPattern: try reader.u32LE())))))
                case UInt8(ascii: "K"): stack.append(Obj(.int(String(try reader.u8()))))
                case UInt8(ascii: "M"): stack.append(Obj(.int(String(try reader.u16LE()))))
                case UInt8(ascii: "L"):
                    var text = try textLine()
                    if text.hasSuffix("L") { text.removeLast() }
                    guard !text.isEmpty, text.dropFirst(text.hasPrefix("-") ? 1 : 0).allSatisfy(\.isNumber) else {
                        throw DecodeError("invalid LONG \(text)")
                    }
                    stack.append(Obj(.int(text)))
                case 0x8A:
                    let n = Int(try reader.u8())
                    stack.append(Obj(.int(BigIntText.fromTwosComplementLE(try reader.read(n)))))
                case 0x8B:
                    let n = Int(Int32(bitPattern: try reader.u32LE()))
                    guard n >= 0 else { throw DecodeError("negative LONG4 size") }
                    stack.append(Obj(.int(BigIntText.fromTwosComplementLE(try reader.read(n)))))
                case UInt8(ascii: "F"):
                    let text = try textLine()
                    guard let d = Double(text) else { throw DecodeError("invalid FLOAT \(text)") }
                    stack.append(Obj(.float(d)))
                case UInt8(ascii: "G"): stack.append(Obj(.float(Double(bitPattern: try reader.u64BE()))))
                case UInt8(ascii: "S"):
                    stack.append(Obj(.str(try pythonStringLiteral(try reader.line()))))
                case UInt8(ascii: "T"):
                    let n = Int(Int32(bitPattern: try reader.u32LE()))
                    stack.append(Obj(.str(latin1OrUTF8(try reader.read(n)))))
                case UInt8(ascii: "U"):
                    stack.append(Obj(.str(latin1OrUTF8(try reader.read(Int(try reader.u8()))))))
                case UInt8(ascii: "V"):
                    stack.append(Obj(.str(rawUnicodeEscape(try reader.line()))))
                case UInt8(ascii: "X"):
                    stack.append(Obj(.str(String(decoding: try reader.read(Int(try reader.u32LE())), as: UTF8.self))))
                case 0x8C:
                    stack.append(Obj(.str(String(decoding: try reader.read(Int(try reader.u8())), as: UTF8.self))))
                case 0x8D:
                    stack.append(Obj(.str(String(decoding: try reader.read(try size64()), as: UTF8.self))))
                case UInt8(ascii: "B"): stack.append(Obj(.bytes(try reader.read(Int(try reader.u32LE())))))
                case UInt8(ascii: "C"): stack.append(Obj(.bytes(try reader.read(Int(try reader.u8())))))
                case 0x8E, 0x96: stack.append(Obj(.bytes(try reader.read(try size64()))))
                case 0x97, 0x98: break // NEXT_BUFFER / READONLY_BUFFER: out-of-band buffers are not available
                case UInt8(ascii: "]"): stack.append(Obj(.list([])))
                case UInt8(ascii: ")"): stack.append(Obj(.tuple([])))
                case UInt8(ascii: "}"): stack.append(Obj(.dict([])))
                case 0x8F: stack.append(Obj(.set([])))
                case UInt8(ascii: "l"): stack.append(Obj(.list(try popMark())))
                case UInt8(ascii: "t"): stack.append(Obj(.tuple(try popMark())))
                case 0x85:
                    let a = try pop()
                    stack.append(Obj(.tuple([a])))
                case 0x86:
                    let b = try pop(), a = try pop()
                    stack.append(Obj(.tuple([a, b])))
                case 0x87:
                    let c = try pop(), b = try pop(), a = try pop()
                    stack.append(Obj(.tuple([a, b, c])))
                case UInt8(ascii: "d"):
                    let items = try popMark()
                    stack.append(Obj(.dict(try pairs(items))))
                case 0x91: stack.append(Obj(.set(try popMark())))
                case UInt8(ascii: "a"):
                    let v = try pop()
                    try append(to: try top(), [v])
                case UInt8(ascii: "e"):
                    let items = try popMark()
                    try append(to: try top(), items)
                case UInt8(ascii: "s"):
                    let v = try pop(), k = try pop()
                    try setItems(on: try top(), [(k, v)])
                case UInt8(ascii: "u"):
                    let items = try popMark()
                    try setItems(on: try top(), try pairs(items))
                case 0x90:
                    let items = try popMark()
                    let target = try top()
                    guard case .set(let existing) = target.kind else { throw DecodeError("ADDITEMS on non-set") }
                    target.kind = .set(existing + items)
                case UInt8(ascii: "0"): _ = try pop()
                case UInt8(ascii: "1"): _ = try popMark()
                case UInt8(ascii: "2"): stack.append(try top())
                case UInt8(ascii: "p"):
                    guard let i = Int(try textLine()) else { throw DecodeError("invalid PUT") }
                    memo[i] = try top()
                case UInt8(ascii: "q"): memo[Int(try reader.u8())] = try top()
                case UInt8(ascii: "r"): memo[Int(try reader.u32LE())] = try top()
                case 0x94: memo[memo.count] = try top()
                case UInt8(ascii: "g"):
                    guard let i = Int(try textLine()), let v = memo[i] else { throw DecodeError("invalid GET") }
                    stack.append(v)
                case UInt8(ascii: "h"):
                    guard let v = memo[Int(try reader.u8())] else { throw DecodeError("invalid BINGET") }
                    stack.append(v)
                case UInt8(ascii: "j"):
                    guard let v = memo[Int(try reader.u32LE())] else { throw DecodeError("invalid LONG_BINGET") }
                    stack.append(v)
                case UInt8(ascii: "c"):
                    let module = try textLine()
                    let name = try textLine()
                    stack.append(Obj(.global(module, name)))
                case 0x93:
                    let name = try pop(), module = try pop()
                    guard case .str(let n) = name.kind, case .str(let m) = module.kind else { throw DecodeError("invalid STACK_GLOBAL") }
                    stack.append(Obj(.global(m, n)))
                case UInt8(ascii: "R"):
                    let args = try pop(), callable = try pop()
                    stack.append(reduce(callable, args: tupleItems(args)))
                case 0x81:
                    let args = try pop(), cls = try pop()
                    stack.append(reduce(cls, args: tupleItems(args)))
                case 0x92:
                    _ = try pop()
                    let args = try pop(), cls = try pop()
                    stack.append(reduce(cls, args: tupleItems(args)))
                case UInt8(ascii: "i"):
                    let module = try textLine()
                    let name = try textLine()
                    let args = try popMark()
                    stack.append(reduce(Obj(.global(module, name)), args: args))
                case UInt8(ascii: "o"):
                    var items = try popMark()
                    guard !items.isEmpty else { throw DecodeError("OBJ without class") }
                    let cls = items.removeFirst()
                    stack.append(reduce(cls, args: items))
                case UInt8(ascii: "b"):
                    let state = try pop()
                    let target = try top()
                    build(target, state: state)
                case 0x82: stack.append(Obj(.global("copyreg", "ext\(try reader.u8())")))
                case 0x83: stack.append(Obj(.global("copyreg", "ext\(try reader.u16LE())")))
                case 0x84: stack.append(Obj(.global("copyreg", "ext\(try reader.u32LE())")))
                case UInt8(ascii: "P"):
                    let id = try textLine()
                    stack.append(Obj(.instance(cls: "persistent_id", args: [Obj(.str(id))], state: nil, items: [], listItems: [])))
                case UInt8(ascii: "Q"):
                    let id = try pop()
                    stack.append(Obj(.instance(cls: "persistent_id", args: [id], state: nil, items: [], listItems: [])))
                default:
                    throw DecodeError("unknown opcode 0x\(String(op, radix: 16)) at offset \(reader.offset - 1)")
                }
            }
        }

        mutating func size64() throws -> Int {
            let n = try reader.u64LE()
            guard n <= UInt64(reader.remaining) else { throw ByteReaderError.truncated }
            return Int(n)
        }

        func pairs(_ items: [Obj]) throws -> [(Obj, Obj)] {
            guard items.count % 2 == 0 else { throw DecodeError("odd number of dict items") }
            return stride(from: 0, to: items.count, by: 2).map { (items[$0], items[$0 + 1]) }
        }

        func tupleItems(_ obj: Obj) -> [Obj] {
            switch obj.kind {
            case .tuple(let items), .list(let items): return items
            default: return [obj]
            }
        }

        func append(to target: Obj, _ items: [Obj]) throws {
            switch target.kind {
            case .list(let existing): target.kind = .list(existing + items)
            case .set(let existing): target.kind = .set(existing + items)
            case .instance(let cls, let args, let state, let dictItems, let listItems):
                target.kind = .instance(cls: cls, args: args, state: state, items: dictItems, listItems: listItems + items)
            default: throw DecodeError("APPEND on non-list")
            }
        }

        func setItems(on target: Obj, _ newItems: [(Obj, Obj)]) throws {
            switch target.kind {
            case .dict(let existing): target.kind = .dict(existing + newItems)
            case .instance(let cls, let args, let state, let items, let listItems):
                target.kind = .instance(cls: cls, args: args, state: state, items: items + newItems, listItems: listItems)
            default: throw DecodeError("SETITEM on non-dict")
            }
        }

        func build(_ target: Obj, state: Obj) {
            switch target.kind {
            case .instance(let cls, let args, _, let items, let listItems):
                target.kind = .instance(cls: cls, args: args, state: state, items: items, listItems: listItems)
            case .dict(let existing):
                if case .dict(let more) = state.kind { target.kind = .dict(existing + more) }
            default:
                break
            }
        }

        func reduce(_ callable: Obj, args: [Obj]) -> Obj {
            guard case .global(let module, let name) = callable.kind else {
                return Obj(.instance(cls: "?", args: args, state: nil, items: [], listItems: []))
            }
            let qualified = module + "." + name
            switch qualified {
            case "builtins.set", "__builtin__.set", "builtins.frozenset", "__builtin__.frozenset":
                return Obj(.set(args.first.map(tupleItems) ?? []))
            case "builtins.list", "__builtin__.list":
                return Obj(.list(args.first.map(tupleItems) ?? []))
            case "builtins.tuple", "__builtin__.tuple":
                return Obj(.tuple(args.first.map(tupleItems) ?? []))
            case "builtins.dict", "__builtin__.dict", "collections.OrderedDict":
                if let first = args.first, case .dict = first.kind { return Obj(first.kind) }
                if let first = args.first, case .list(let items) = first.kind {
                    let pairs = items.compactMap { item -> (Obj, Obj)? in
                        let t = tupleItems(item)
                        return t.count == 2 ? (t[0], t[1]) : nil
                    }
                    return Obj(.dict(pairs))
                }

                return Obj(.dict([]))
            case "builtins.bytearray", "__builtin__.bytearray", "builtins.bytes", "_codecs.encode":
                if let first = args.first {
                    switch first.kind {
                    case .bytes: return Obj(first.kind)
                    case .str(let s): return Obj(.bytes(Array(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })))
                    case .list(let items):
                        return Obj(.bytes(items.compactMap { o -> UInt8? in
                            if case .int(let t) = o.kind { return UInt8(t) }
                            return nil
                        }))
                    default: break
                    }
                }

                return Obj(.bytes([]))
            case "decimal.Decimal":
                if let first = args.first, case .str(let s) = first.kind { return Obj(.int(s)) }
            case "datetime.datetime", "datetime.date", "datetime.time":
                if let first = args.first, case .bytes(let b) = first.kind, let text = dateText(name: name, bytes: b) {
                    return Obj(.str(text))
                }

                if let first = args.first, case .str(let s) = first.kind, let text = dateText(name: name, bytes: latin1Bytes(s)) {
                    return Obj(.str(text))
                }
            default:
                break
            }

            return Obj(.instance(cls: qualified, args: args, state: nil, items: [], listItems: []))
        }

        func dateText(name: String, bytes b: [UInt8]) -> String? {
            switch (name, b.count) {
            case ("datetime", 10):
                let year = Int(b[0]) << 8 | Int(b[1])
                let usec = Int(b[7]) << 16 | Int(b[8]) << 8 | Int(b[9])
                return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%06d", year, b[2], b[3], b[4], b[5], b[6], usec)
            case ("date", 4):
                let year = Int(b[0]) << 8 | Int(b[1])
                return String(format: "%04d-%02d-%02d", year, b[2], b[3])
            case ("time", 6):
                let usec = Int(b[3]) << 16 | Int(b[4]) << 8 | Int(b[5])
                return String(format: "%02d:%02d:%02d.%06d", b[0], b[1], b[2], usec)
            default:
                return nil
            }
        }
    }

    // MARK: JSON mapping

    /// Detects cycles on the current path and limits nodes to bound expansion of shared references.
    final class Walk {
        var path = Set<ObjectIdentifier>()
        var budget = 500_000
    }

    static func json(_ obj: Obj, depth: Int) -> JSONValue {
        json(obj, walk: Walk())
    }

    static func json(_ obj: Obj, walk: Walk) -> JSONValue {
        walk.budget -= 1
        guard walk.budget > 0, walk.path.count < 300 else { return .string("…") }
        let id = ObjectIdentifier(obj)
        guard walk.path.insert(id).inserted else { return .string("[Circular]") }
        defer { walk.path.remove(id) }
        switch obj.kind {
        case .none, .mark: return .null
        case .bool(let b): return .bool(b)
        case .int(let t): return .number(t)
        case .float(let d): return .double(d)
        case .str(let s): return .string(s)
        case .bytes(let b): return .string(TextBytes.displayString(b))
        case .list(let items), .tuple(let items), .set(let items):
            return .array(items.map { json($0, walk: walk) })
        case .dict(let pairs):
            return .object(pairs.map { JSONMember(key: keyText($0.0, walk: walk), value: json($0.1, walk: walk)) })
        case .global(let module, let name):
            return .string(module + "." + name)
        case .instance(let cls, let args, let state, let items, let listItems):
            var members = [JSONMember(key: "__class__", value: .string(cls))]
            if !args.isEmpty { members.append(JSONMember(key: "args", value: .array(args.map { json($0, walk: walk) }))) }
            if let state { members.append(JSONMember(key: "state", value: json(state, walk: walk))) }
            if !items.isEmpty {
                members.append(JSONMember(key: "items", value: .object(items.map {
                    JSONMember(key: keyText($0.0, walk: walk), value: json($0.1, walk: walk))
                })))
            }

            if !listItems.isEmpty {
                members.append(JSONMember(key: "listItems", value: .array(listItems.map { json($0, walk: walk) })))
            }

            return .object(members)
        }
    }

    static func keyText(_ obj: Obj, walk: Walk) -> String {
        switch obj.kind {
        case .str(let s): return s
        case .none: return "None"
        case .bool(let b): return b ? "True" : "False"
        default: return Msgpack.keyText(json(obj, walk: walk))
        }
    }

    static func latin1OrUTF8(_ bytes: [UInt8]) -> String {
        String(strictUTF8: bytes) ?? String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    static func latin1Bytes(_ s: String) -> [UInt8] {
        s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }

    /// Protocol 0 `STRING` uses a quoted Python repr such as `'abc\n'`.
    static func pythonStringLiteral(_ line: [UInt8]) throws -> String {
        var bytes = line
        if bytes.last == 0x0D { bytes.removeLast() }
        guard bytes.count >= 2, let q = bytes.first, q == 0x27 || q == 0x22, bytes.last == q else {
            throw DecodeError("invalid STRING literal")
        }
        let body = Array(bytes[1..<bytes.count - 1])
        var out: [UInt8] = []
        var i = 0
        while i < body.count {
            if body[i] == 0x5C, i + 1 < body.count {
                let n = body[i + 1]
                switch n {
                case UInt8(ascii: "n"): out.append(0x0A); i += 2
                case UInt8(ascii: "r"): out.append(0x0D); i += 2
                case UInt8(ascii: "t"): out.append(0x09); i += 2
                case UInt8(ascii: "x") where i + 3 < body.count:
                    if let h = hexDigit(body[i + 2]), let l = hexDigit(body[i + 3]) { out.append(h << 4 | l); i += 4 } else { out.append(n); i += 2 }
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var v = 0
                    var k = i + 1
                    while k < body.count, k < i + 4, (0x30...0x37).contains(body[k]) {
                        v = v * 8 + Int(body[k] - 0x30)
                        k += 1
                    }

                    out.append(UInt8(truncatingIfNeeded: v))
                    i = k
                default: out.append(n); i += 2
                }
            } else {
                out.append(body[i])
                i += 1
            }
        }

        return latin1OrUTF8(out)
    }

    /// Protocol 0 `UNICODE` argument (`raw-unicode-escape`).
    static func rawUnicodeEscape(_ line: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        var i = 0
        while i < line.count {
            if line[i] == 0x5C, i + 1 < line.count, line[i + 1] == UInt8(ascii: "u") || line[i + 1] == UInt8(ascii: "U") {
                let width = line[i + 1] == UInt8(ascii: "u") ? 4 : 8
                if i + 2 + width <= line.count {
                    var v: UInt32 = 0
                    var ok = true
                    for k in 0..<width {
                        guard let d = hexDigit(line[i + 2 + k]) else { ok = false; break }
                        v = v << 4 | UInt32(d)
                    }

                    if ok, let s = Unicode.Scalar(v) {
                        scalars.append(s)
                        i += 2 + width
                        continue
                    }
                }
            }

            scalars.append(Unicode.Scalar(line[i]))
            i += 1
        }

        return String(scalars)
    }
}
