// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Decodes the bounded MessagePack documents in Lightroom's local metadata cache.
/// It does not evaluate Lua or execute any content from the catalog.
struct MessagePackDecoder {
    enum Failure: Error { case truncated, unsupported(UInt8), invalidMapKey, oversized, invalidUTF8 }
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.oversized }
        bytes = Array(data)
    }

    mutating func decode() throws -> Any { try value(depth: 0) }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.count - offset else { throw Failure.truncated }
        let start = offset
        offset += count
        return bytes[start..<offset]
    }

    private mutating func unsigned(_ count: Int) throws -> UInt64 {
        try take(count).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private mutating func string(_ count: Int) throws -> String {
        guard let result = String(bytes: try take(count), encoding: .utf8) else { throw Failure.invalidUTF8 }
        return result
    }

    private mutating func array(_ count: Int, depth: Int) throws -> [Any] {
        guard count <= 100_000 else { throw Failure.oversized }
        return try (0..<count).map { _ in try value(depth: depth + 1) }
    }

    private mutating func map(_ count: Int, depth: Int) throws -> [String: Any] {
        guard count <= 100_000 else { throw Failure.oversized }
        var result: [String: Any] = [:]
        for _ in 0..<count {
            guard let key = try value(depth: depth + 1) as? String else { throw Failure.invalidMapKey }
            result[key] = try value(depth: depth + 1)
        }
        return result
    }

    private mutating func value(depth: Int) throws -> Any {
        guard depth < 64 else { throw Failure.oversized }
        let tag = UInt8(try unsigned(1))
        switch tag {
        case 0x00...0x7f: return Int(tag)
        case 0x80...0x8f: return try map(Int(tag & 0x0f), depth: depth)
        case 0x90...0x9f: return try array(Int(tag & 0x0f), depth: depth)
        case 0xa0...0xbf: return try string(Int(tag & 0x1f))
        case 0xc0: return NSNull()
        case 0xc2: return false
        case 0xc3: return true
        case 0xc4: return Data(try take(Int(try unsigned(1))))
        case 0xc5: return Data(try take(Int(try unsigned(2))))
        case 0xc6: return Data(try take(Int(try unsigned(4))))
        case 0xca: return Double(Float(bitPattern: UInt32(try unsigned(4))))
        case 0xcb: return Double(bitPattern: try unsigned(8))
        case 0xcc: return Int(try unsigned(1))
        case 0xcd: return Int(try unsigned(2))
        case 0xce: return Int(try unsigned(4))
        case 0xcf: return NSNumber(value: try unsigned(8))
        case 0xd0: return Int(Int8(bitPattern: UInt8(try unsigned(1))))
        case 0xd1: return Int(Int16(bitPattern: UInt16(try unsigned(2))))
        case 0xd2: return Int(Int32(bitPattern: UInt32(try unsigned(4))))
        case 0xd3: return Int64(bitPattern: try unsigned(8))
        case 0xd9: return try string(Int(try unsigned(1)))
        case 0xda: return try string(Int(try unsigned(2)))
        case 0xdb: return try string(Int(try unsigned(4)))
        case 0xdc: return try array(Int(try unsigned(2)), depth: depth)
        case 0xdd: return try array(Int(try unsigned(4)), depth: depth)
        case 0xde: return try map(Int(try unsigned(2)), depth: depth)
        case 0xdf: return try map(Int(try unsigned(4)), depth: depth)
        case 0xe0...0xff: return Int(Int8(bitPattern: tag))
        default: throw Failure.unsupported(tag)
        }
    }
}
