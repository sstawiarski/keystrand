import Foundation

/// Read-only decoder for the Java Object Serialization Stream Protocol (`ac ed 00 05`).
///
/// Strings, boxed primitives, `BigInteger`/`BigDecimal`, `Date`, enums, arrays, and the common collections
/// (`ArrayList`, `LinkedList`, `HashMap`, `LinkedHashMap`, `TreeMap`, `HashSet`, `LinkedHashSet`, `TreeSet`,
/// `Arrays$ArrayList`, `Collections` wrappers) map to natural JSON. Other objects become
/// `{"className", "serialVersionUid", "fields": [{name: value}], "annotations"}`.
enum JavaSerialization {
    struct DecodeError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    static func decode(_ bytes: [UInt8]) throws -> JSONValue {
        var stream = Stream(reader: ByteReader(bytes))
        guard try stream.reader.u16BE() == 0xACED else { throw DecodeError("missing Java serialization magic") }
        guard try stream.reader.u16BE() == 5 else { throw DecodeError("unsupported stream version") }
        var contents: [JSONValue] = []
        while !stream.reader.isAtEnd {
            let item = try stream.content()
            switch item {
            case .object(let o): contents.append(stream.json(o, depth: 0))
            case .block(let b): contents.append(.string(b.hexString))
            case .end: break
            }
        }

        guard let first = contents.first else { throw DecodeError("empty stream") }
        return contents.count == 1 ? first : .array(contents)
    }

    /// Limit on object and class descriptor nesting (one shared count) and on the length of a class hierarchy.
    static let maxDepth = 256

    /// Reserves 128 KB for parser and JSON mapping frames because `maxDepth` can overflow a 512 KB task-thread stack in Debug builds.
    static let stackReserve = 128 * 1024

    static func hasStackHeadroom() -> Bool {
        let thread = pthread_self()
        let high = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let low = high &- UInt(pthread_get_stacksize_np(thread))
        var marker: UInt8 = 0
        let current = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        guard current > low, current <= high else { return true }
        return current - low > UInt(stackReserve)
    }

    // MARK: Model

    final class ClassDesc {
        var name: String
        var uid: Int64
        var flags: UInt8 = 0
        var fields: [Field] = []
        private(set) var superclass: ClassDesc?
        /// Descriptors from this one to the root of its hierarchy, this one included.
        private(set) var chainLength = 1
        private(set) var isComplete = false
        var isProxy = false

        init(name: String, uid: Int64) {
            self.name = name
            self.uid = uid
        }

        /// Requires a completed superclass with a fixed chain to prevent cycles and keep `chainLength` exact.
        func complete(superclass: ClassDesc?) throws {
            if let superclass {
                guard superclass !== self, superclass.isComplete else {
                    throw DecodeError("cyclic class hierarchy in \(name)")
                }
                guard superclass.chainLength < JavaSerialization.maxDepth else {
                    throw DecodeError("class hierarchy too deep")
                }
            }

            self.superclass = superclass
            chainLength = (superclass?.chainLength ?? 0) + 1
            isComplete = true
        }

        /// Root class first.
        func hierarchy() throws -> [ClassDesc] {
            var chain: [ClassDesc] = []
            chain.reserveCapacity(chainLength)
            var next: ClassDesc? = self
            while let current = next {
                guard chain.count < JavaSerialization.maxDepth else { throw DecodeError("class hierarchy too deep") }
                chain.append(current)
                next = current.superclass
            }

            return chain.reversed()
        }
    }

    struct Field {
        var type: UInt8
        var name: String
        var className: String?
    }

    final class ClassData {
        let desc: ClassDesc
        var values: [(String, Value)] = []
        var annotations: [Item] = []
        init(desc: ClassDesc) { self.desc = desc }
    }

    final class InstanceBox {
        var desc: ClassDesc
        var classData: [ClassData] = []
        init(desc: ClassDesc) { self.desc = desc }
    }

    indirect enum Value {
        case null
        case primitive(JSONValue)
        case string(String)
        case instance(InstanceBox)
        case array(ClassDesc, [Value])
        case classRef(ClassDesc)
        case enumConstant(ClassDesc, String)
        case classDesc(ClassDesc)
    }

    enum Item {
        case object(Value)
        case block([UInt8])
        case end
    }

    enum Handle {
        case value(Value)
        case desc(ClassDesc)
    }

    // MARK: Stream parser

    struct Stream {
        var reader: ByteReader
        var handles: [Handle] = []
        var depth = 0
        let walk = Pickle.Walk()

        mutating func newHandle(_ h: Handle) -> Int {
            handles.append(h)
            return handles.count - 1
        }

        mutating func utf() throws -> String {
            let n = Int(try reader.u16BE())
            return modifiedUTF8(try reader.read(n))
        }

        mutating func content() throws -> Item {
            let tc = try reader.peek()
            switch tc {
            case 0x77:
                _ = try reader.u8()
                return .block(try reader.read(Int(try reader.u8())))
            case 0x7A:
                _ = try reader.u8()
                let n = Int(Int32(bitPattern: try reader.u32BE()))
                guard n >= 0 else { throw DecodeError("negative block size") }
                return .block(try reader.read(n))
            case 0x78:
                _ = try reader.u8()
                return .end
            default:
                return .object(try object())
            }
        }

        mutating func object() throws -> Value {
            try enterNesting()
            defer { depth -= 1 }
            let tc = try reader.u8()
            switch tc {
            case 0x70: return .null
            case 0x71:
                let handle = Int(try reader.u32BE()) - 0x7E0000
                guard handle >= 0, handle < handles.count else { throw DecodeError("invalid handle") }
                switch handles[handle] {
                case .value(let v): return v
                case .desc(let d): return .classDesc(d)
                }
            case 0x72, 0x7D:
                reader.offset -= 1
                guard let desc = try classDesc() else { return .null }
                return .classDesc(desc)
            case 0x73: return try newObject()
            case 0x74:
                let s = try utf()
                let v = Value.string(s)
                _ = newHandle(.value(v))
                return v
            case 0x7C:
                let length = try reader.u64BE()
                guard length <= UInt64(reader.remaining) else { throw DecodeError("invalid string length") }
                let s = modifiedUTF8(try reader.read(Int(length)))
                let v = Value.string(s)
                _ = newHandle(.value(v))
                return v
            case 0x75: return try newArray()
            case 0x76:
                guard let desc = try classDesc() else { throw DecodeError("class without descriptor") }
                let v = Value.classRef(desc)
                _ = newHandle(.value(v))
                return v
            case 0x7E:
                guard let desc = try classDesc() else { throw DecodeError("enum without descriptor") }
                let slot = newHandle(.value(.null))
                guard case .string(let name) = try object() else { throw DecodeError("enum constant name missing") }
                let v = Value.enumConstant(desc, name)
                handles[slot] = .value(v)
                return v
            case 0x79:
                handles.removeAll()
                return try object()
            case 0x7B:
                throw DecodeError("stream contains a serialized exception")
            default:
                throw DecodeError("unexpected type code 0x\(String(tc, radix: 16)) at offset \(reader.offset - 1)")
            }
        }

        mutating func enterNesting() throws {
            depth += 1
            guard depth < JavaSerialization.maxDepth, JavaSerialization.hasStackHeadroom() else {
                depth -= 1
                throw DecodeError("nesting too deep")
            }
        }

        mutating func classDesc() throws -> ClassDesc? {
            try enterNesting()
            defer { depth -= 1 }
            let tc = try reader.u8()
            switch tc {
            case 0x70:
                return nil
            case 0x71:
                let handle = Int(try reader.u32BE()) - 0x7E0000
                guard handle >= 0, handle < handles.count else { throw DecodeError("invalid handle") }
                if case .desc(let d) = handles[handle] { return d }
                throw DecodeError("handle is not a class descriptor")
            case 0x72:
                let name = try utf()
                let uid = Int64(bitPattern: try reader.u64BE())
                let desc = ClassDesc(name: name, uid: uid)
                _ = newHandle(.desc(desc))
                desc.flags = try reader.u8()
                let count = Int(try reader.u16BE())
                for _ in 0..<count {
                    let type = try reader.u8()
                    let fieldName = try utf()
                    var className: String?
                    if type == UInt8(ascii: "L") || type == UInt8(ascii: "[") {
                        guard case .string(let cn) = try object() else { throw DecodeError("field class name missing") }
                        className = cn
                    }

                    desc.fields.append(Field(type: type, name: fieldName, className: className))
                }

                try skipAnnotations()
                try desc.complete(superclass: try classDesc())
                return desc
            case 0x7D:
                let desc = ClassDesc(name: "Proxy", uid: 0)
                desc.isProxy = true
                _ = newHandle(.desc(desc))
                let count = Int(try reader.u32BE())
                var names: [String] = []
                for _ in 0..<count { names.append(try utf()) }
                desc.name = "Proxy(" + names.joined(separator: ", ") + ")"
                try skipAnnotations()
                try desc.complete(superclass: try classDesc())
                return desc
            default:
                throw DecodeError("expected class descriptor, found 0x\(String(tc, radix: 16))")
            }
        }

        mutating func skipAnnotations() throws {
            while true {
                if case .end = try content() { return }
            }
        }

        mutating func annotations() throws -> [Item] {
            var items: [Item] = []
            while true {
                let item = try content()
                if case .end = item { return items }
                items.append(item)
            }
        }

        mutating func newObject() throws -> Value {
            guard let desc = try classDesc() else { throw DecodeError("object without class descriptor") }
            let box = InstanceBox(desc: desc)
            let value = Value.instance(box)
            _ = newHandle(.value(value))
            for cls in try desc.hierarchy() {
                let data = ClassData(desc: cls)
                box.classData.append(data)
                if cls.flags & 0x04 != 0 {
                    guard cls.flags & 0x08 != 0 else { throw DecodeError("externalizable data without block mode") }
                    data.annotations = try annotations()
                    continue
                }

                guard cls.flags & 0x02 != 0 else { continue }
                for field in cls.fields {
                    data.values.append((field.name, try fieldValue(field.type)))
                }

                if cls.flags & 0x01 != 0 {
                    data.annotations = try annotations()
                }
            }

            return value
        }

        mutating func fieldValue(_ type: UInt8) throws -> Value {
            switch type {
            case UInt8(ascii: "B"): return .primitive(.integer(Int8(bitPattern: try reader.u8())))
            case UInt8(ascii: "C"): return .primitive(.string(String(utf16CodeUnits: [try reader.u16BE()], count: 1)))
            case UInt8(ascii: "D"): return .primitive(.double(Double(bitPattern: try reader.u64BE())))
            case UInt8(ascii: "F"): return .primitive(.float(Float(bitPattern: try reader.u32BE())))
            case UInt8(ascii: "I"): return .primitive(.integer(Int32(bitPattern: try reader.u32BE())))
            case UInt8(ascii: "J"): return .primitive(.integer(Int64(bitPattern: try reader.u64BE())))
            case UInt8(ascii: "S"): return .primitive(.integer(Int16(bitPattern: try reader.u16BE())))
            case UInt8(ascii: "Z"): return .primitive(.bool(try reader.u8() != 0))
            case UInt8(ascii: "L"), UInt8(ascii: "["): return try object()
            default: throw DecodeError("unknown field type '\(Character(Unicode.Scalar(type)))'")
            }
        }

        mutating func newArray() throws -> Value {
            guard let desc = try classDesc() else { throw DecodeError("array without class descriptor") }
            let slot = newHandle(.value(.null))
            let count = Int(Int32(bitPattern: try reader.u32BE()))
            guard count >= 0, count <= reader.remaining else { throw DecodeError("invalid array length") }
            let elementType = desc.name.utf8.dropFirst().first ?? UInt8(ascii: "L")
            var items: [Value] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try fieldValue(elementType)) }
            let v = Value.array(desc, items)
            handles[slot] = .value(v)
            return v
        }

        // MARK: JSON mapping

        func json(_ value: Value, depth: Int) -> JSONValue {
            walk.budget -= 1
            guard depth < JavaSerialization.maxDepth, walk.budget > 0, JavaSerialization.hasStackHeadroom() else {
                return .string("…")
            }
            switch value {
            case .null: return .null
            case .primitive(let p): return p
            case .string(let s): return .string(s)
            case .classRef(let d): return .string("class " + d.name)
            case .classDesc(let d): return .string("class " + d.name)
            case .enumConstant(_, let name): return .string(name)
            case .array(let desc, let items):
                if desc.name == "[B" {
                    let bytes = items.compactMap { v -> UInt8? in
                        if case .primitive(.number(let n)) = v, let i = Int8(n) { return UInt8(bitPattern: i) }
                        return nil
                    }
                    return .string(TextBytes.displayString(bytes))
                }

                return .array(items.map { json($0, depth: depth + 1) })
            case .instance(let box):
                let id = ObjectIdentifier(box)
                guard walk.path.insert(id).inserted else { return .string("[Circular]") }
                defer { walk.path.remove(id) }
                return instanceJSON(box, depth: depth)
            }
        }

        func field(_ box: InstanceBox, _ name: String) -> Value? {
            for data in box.classData.reversed() {
                if let v = data.values.first(where: { $0.0 == name })?.1 { return v }
            }

            return nil
        }

        func annotationObjects(_ box: InstanceBox) -> [Value] {
            box.classData.flatMap { data in
                data.annotations.compactMap { item -> Value? in
                    if case .object(let v) = item { return v }
                    return nil
                }
            }
        }

        func annotationBlock(_ box: InstanceBox) -> [UInt8] {
            box.classData.flatMap { data in
                data.annotations.flatMap { item -> [UInt8] in
                    if case .block(let b) = item { return b }
                    return []
                }
            }
        }

        func instanceJSON(_ box: InstanceBox, depth: Int) -> JSONValue {
            let name = box.desc.name
            switch name {
            case "java.lang.Integer", "java.lang.Long", "java.lang.Short", "java.lang.Byte", "java.lang.Double",
                 "java.lang.Float", "java.lang.Boolean", "java.lang.Character":
                return field(box, "value").map { json($0, depth: depth + 1) } ?? .null
            case "java.math.BigInteger":
                return bigInteger(box) ?? genericJSON(box, depth: depth)
            case "java.math.BigDecimal":
                if case .instance(let unscaledBox)? = field(box, "intVal"), let unscaled = bigInteger(unscaledBox),
                   case .number(let digits) = unscaled,
                   case .primitive(.number(let scaleText))? = field(box, "scale"), let scale = Int(scaleText) {
                    return .number(BigIntText.applyScale(digits, scale: scale))
                }

                return genericJSON(box, depth: depth)
            case "java.util.Date":
                let block = annotationBlock(box)
                guard block.count >= 8 else { return genericJSON(box, depth: depth) }
                var r = ByteReader(block)
                guard let raw = try? r.u64BE() else { return genericJSON(box, depth: depth) }
                let ms = Int64(bitPattern: raw)
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                f.timeZone = TimeZone(identifier: "UTC")
                return .string(f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)))
            case "java.util.ArrayList", "java.util.LinkedList", "java.util.ArrayDeque", "java.util.Vector",
                 "java.util.HashSet", "java.util.LinkedHashSet", "java.util.TreeSet", "java.util.concurrent.CopyOnWriteArrayList":
                if name == "java.util.Vector", case .array(_, let items)? = field(box, "elementData") {
                    let count = field(box, "elementCount").flatMap { v -> Int? in
                        if case .primitive(.number(let n)) = v { return Int(n) }
                        return nil
                    } ?? items.count
                    return .array(items.prefix(max(0, count)).map { json($0, depth: depth + 1) })
                }

                return .array(annotationObjects(box).map { json($0, depth: depth + 1) })
            case "java.util.HashMap", "java.util.LinkedHashMap", "java.util.TreeMap", "java.util.Hashtable",
                 "java.util.concurrent.ConcurrentHashMap", "java.util.Properties":
                let objects = annotationObjects(box).filter {
                    if case .instance(let b) = $0, b.desc.name.hasPrefix("java.util.concurrent.ConcurrentHashMap$Segment") { return false }
                    return true
                }
                var members: [JSONMember] = []
                var i = 0
                while i + 1 < objects.count {
                    members.append(JSONMember(key: Msgpack.keyText(json(objects[i], depth: depth + 1)),
                                              value: json(objects[i + 1], depth: depth + 1)))
                    i += 2
                }

                return .object(members)
            case "java.util.Arrays$ArrayList":
                if let a = field(box, "a") { return json(a, depth: depth + 1) }
                return genericJSON(box, depth: depth)
            default:
                if name.hasPrefix("java.util.Collections$"), let inner = field(box, "c") ?? field(box, "m") ?? field(box, "list") {
                    return json(inner, depth: depth + 1)
                }

                if name.hasPrefix("java.util.Collections$Singleton"), let element = field(box, "element") {
                    return .array([json(element, depth: depth + 1)])
                }

                if name.hasPrefix("java.util.Collections$Empty") { return name.hasSuffix("Map") ? .object([]) : .array([]) }
                if name == "java.util.ImmutableCollections$ListN" || name == "java.util.CollSer" {
                    return .array(annotationObjects(box).map { json($0, depth: depth + 1) })
                }

                return genericJSON(box, depth: depth)
            }
        }

        func bigInteger(_ box: InstanceBox) -> JSONValue? {
            guard case .array(_, let items)? = field(box, "magnitude"),
                  case .primitive(.number(let signText))? = field(box, "signum"), let signum = Int(signText) else { return nil }
            let bytes = items.compactMap { v -> UInt8? in
                if case .primitive(.number(let n)) = v, let i = Int8(n) { return UInt8(bitPattern: i) }
                return nil
            }
            return .number(BigIntText.fromMagnitude(bigEndian: bytes, negative: signum < 0))
        }

        func genericJSON(_ box: InstanceBox, depth: Int) -> JSONValue {
            var fields: [JSONValue] = []
            for data in box.classData {
                for (name, value) in data.values {
                    fields.append(.object([JSONMember(key: name, value: json(value, depth: depth + 1))]))
                }
            }

            let annotations: [JSONValue] = box.classData.flatMap { data in
                data.annotations.compactMap { item -> JSONValue? in
                    switch item {
                    case .object(let v): return json(v, depth: depth + 1)
                    case .block(let b): return .string(b.hexString)
                    case .end: return nil
                    }
                }
            }
            return .object([
                JSONMember(key: "className", value: .string(box.desc.name)),
                JSONMember(key: "serialVersionUid", value: .integer(box.desc.uid)),
                JSONMember(key: "fields", value: .array(fields)),
                JSONMember(key: "annotations", value: .array(annotations)),
            ])
        }
    }

    /// Java modified UTF-8 encodes NUL as `C0 80` and surrogate pairs as two 3-byte sequences.
    static func modifiedUTF8(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b < 0x80 {
                units.append(UInt16(b))
                i += 1
            } else if b & 0xE0 == 0xC0, i + 1 < bytes.count {
                units.append(UInt16(b & 0x1F) << 6 | UInt16(bytes[i + 1] & 0x3F))
                i += 2
            } else if b & 0xF0 == 0xE0, i + 2 < bytes.count {
                units.append(UInt16(b & 0x0F) << 12 | UInt16(bytes[i + 1] & 0x3F) << 6 | UInt16(bytes[i + 2] & 0x3F))
                i += 3
            } else {
                units.append(0xFFFD)
                i += 1
            }
        }

        return String(decoding: units, as: UTF16.self)
    }
}
