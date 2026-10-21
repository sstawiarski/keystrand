import Foundation

/// A Redis command argument. Sends `.data` verbatim.
public enum RedisArgument: Hashable, Sendable {
    case string(String)
    case data(Data)
    case int(Int64)
    case uint(UInt64)
    case double(Double)

    /// Wire bytes of the argument.
    public var data: Data {
        switch self {
        case .string(let s): return Data(s.utf8)
        case .data(let d): return d
        case .int(let i): return Data(String(i).utf8)
        case .uint(let u): return Data(String(u).utf8)
        case .double(let d): return Data(RedisArgument.format(d).utf8)
        }
    }

    /// Redis-compatible double text (`inf`, `-inf`, integral values without a fraction).
    public static func format(_ value: Double) -> String {
        if value.isInfinite { return value > 0 ? "inf" : "-inf" }
        if value.isNaN { return "nan" }
        if value == value.rounded(), abs(value) < 1e17 { return String(Int64(value)) }
        return String(value)
    }
}

extension RedisArgument: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension RedisArgument: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension RedisArgument: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

/// Anything that can be turned into a `RedisArgument`.
public protocol RedisArgumentConvertible {
    var redisArgument: RedisArgument { get }
}

extension RedisArgument: RedisArgumentConvertible { public var redisArgument: RedisArgument { self } }
extension String: RedisArgumentConvertible { public var redisArgument: RedisArgument { .string(self) } }
extension Substring: RedisArgumentConvertible { public var redisArgument: RedisArgument { .string(String(self)) } }
extension Data: RedisArgumentConvertible { public var redisArgument: RedisArgument { .data(self) } }
extension Int: RedisArgumentConvertible { public var redisArgument: RedisArgument { .int(Int64(self)) } }
extension Int64: RedisArgumentConvertible { public var redisArgument: RedisArgument { .int(self) } }
extension UInt64: RedisArgumentConvertible { public var redisArgument: RedisArgument { .uint(self) } }
extension Double: RedisArgumentConvertible { public var redisArgument: RedisArgument { .double(self) } }

public extension Array where Element == Data {
    /// Converts a command’s raw bytes to wire arguments.
    var redisArguments: [RedisArgument] { map(RedisArgument.data) }
}

public extension Array where Element == String {
    var redisArguments: [RedisArgument] { map(RedisArgument.string) }
}
