//
//  Row.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

/// A contiguous byte buffer that backs the cell values of a single ``QueryResult``.
///
/// Drivers copy every cell's raw bytes into one arena per result instead of
/// allocating a Swift `String` per cell. Fields reference slices of this buffer
/// by `(offset, length)` and only materialize a `String` on demand (see
/// ``GenericField/value``). The bytes are immutable once the arena is built,
/// which is what makes it safe to share across threads.
public final class FieldArena: @unchecked Sendable {

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

}

public struct GenericField: @unchecked Sendable, Equatable {

    @usableFromInline
    enum Backing {
        case null
        /// Already-decoded string (legacy path, used by drivers not yet migrated).
        case string(String)
        /// A slice of a shared ``FieldArena``, decoded to `String` lazily.
        case bytes(FieldArena, offset: Int, length: Int)
    }

    @usableFromInline
    var backing: Backing

    /// Legacy initializer. Existing call sites keep working unchanged; the value
    /// is stored eagerly as a `String`.
    public init(value: String?) {
        self.backing = value.map { .string($0) } ?? .null
    }

    /// Fast path: reference `length` bytes at `offset` inside `arena` without
    /// decoding. The `String` is produced on first access to ``value``.
    public init(arena: FieldArena, offset: Int, length: Int) {
        self.backing = .bytes(arena, offset: offset, length: length)
    }

    /// The materialized cell value. For arena-backed fields this decodes UTF-8
    /// on each access (no caching yet), so prefer the byte-level accessors below
    /// on hot paths where a full `String` isn't required.
    public var value: String? {
        get {
            switch backing {
            case .null:
                return nil
            case .string(let string):
                return string
            case .bytes(let arena, let offset, let length):
                return arena.bytes.withUnsafeBufferPointer { buffer in
                    String(decoding: UnsafeBufferPointer(rebasing: buffer[offset..<offset + length]), as: UTF8.self)
                }
            }
        }
        set {
            if let newValue {
                backing = .string(newValue)
            } else {
                backing = .null
            }
        }
    }

    /// `true` when the cell is SQL `NULL`. Cheap: never decodes.
    @inlinable
    public var isNull: Bool {
        if case .null = backing { return true }
        return false
    }

    public static func == (lhs: GenericField, rhs: GenericField) -> Bool {
        lhs.value == rhs.value
    }

}

public struct GenericRow: @unchecked Sendable, Identifiable {

    public typealias ID = Int

    public let id: ID
    public var data: [GenericField]

    public init(id: ID, data: [GenericField]) {
        self.id = id
        self.data = data
    }

}

public protocol Column: Sendable, Identifiable where ID == Int {
    var id: ID { get } // should be the index of column in results
    var name: String { get }
    var type: GenericType { get }
}

public struct ExecutionInfo {

    public let duration: TimeInterval

    public init(duration: TimeInterval) {
        self.duration = duration
    }

}

public final class QueryResult: @unchecked Sendable {

    public static let empty = QueryResult(columns: [], rows: [], executionInfo: .init(duration: 0))

    public let columns: [any Column]
    public var rows: [GenericRow]
    public let executionInfo: ExecutionInfo

    public init(columns: [any Column], rows: [GenericRow], executionInfo: ExecutionInfo) {
        self.columns = columns
        self.rows = rows
        self.executionInfo = executionInfo
    }

}

public enum TypeCategory: Equatable, Sendable {
    case integer, float
    case nchar, varchar, text
    case binary
    case date, time, datetime, interval
    case boolean
    case enumeration
    case xml, json
    case spatial
    case array
    case userDefined
    case system
    case unknown
}

public protocol SqlType {
    var name: String { get }
    var genericType: GenericType { get }
}

public struct GenericType: Sendable {

    public let name: String
    public let category: TypeCategory

    public init(name: String, category: TypeCategory) {
        self.name = name
        self.category = category
    }

}
