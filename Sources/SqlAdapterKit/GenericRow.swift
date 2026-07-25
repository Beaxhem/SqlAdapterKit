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
/// by `(offset, length)` — indices, not pointers, so they survive the buffer's
/// growth — and only materialize a `String` on demand (see ``GenericField/value``).
///
/// The arena is written exactly once, by a single ``QueryResultArenaBuilder`` on
/// one thread during ingest, and is only read afterwards. That build-then-freeze
/// discipline (which the builder enforces by never exposing a still-growing
/// arena) is what makes `@unchecked Sendable` sound.
public final class FieldArena: @unchecked Sendable {

    public private(set) var bytes: [UInt8]

    public init(bytes: [UInt8] = []) {
        self.bytes = bytes
    }

    func reserveCapacity(_ minimumCapacity: Int) {
        bytes.reserveCapacity(minimumCapacity)
    }

    /// Appends `length` raw bytes from `pointer` and returns the offset they
    /// were written at. Build-phase only; see the type's discussion.
    func append(_ pointer: UnsafeRawPointer, length: Int) -> Int {
        let offset = bytes.count
        if length > 0 {
            bytes.append(contentsOf: UnsafeRawBufferPointer(start: pointer, count: length))
        }
        return offset
    }

}

public struct GenericField: @unchecked Sendable, Equatable {
    enum Backing {
        case null
        /// Already-decoded string (legacy path, used by drivers not yet migrated).
        case string(String)
        /// A slice of a shared ``FieldArena``, decoded to `String` lazily.
        case bytes(FieldArena, offset: Int, length: Int)
    }
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
    public var isNull: Bool {
        if case .null = backing { return true }
        return false
    }

    public static func == (lhs: GenericField, rhs: GenericField) -> Bool {
        lhs.value == rhs.value
    }

}

/// A cell's location within a ``FlatResultStore``'s arena. A negative `length`
/// marks SQL `NULL`. Packed into one flat array per result so rows cost no
/// per-row allocation and carry no per-field `FieldArena` reference.
struct FieldSlot: Sendable {
    var offset: Int
    /// Byte length, or a negative value for SQL `NULL`.
    var length: Int

    static var null: FieldSlot { .init(offset: 0, length: -1) }
    var isNull: Bool { length < 0 }
}

/// Column-count + one flat `[FieldSlot]` array backing every row of a result,
/// all sharing a single ``FieldArena``. A row is addressed by index; a cell is
/// `slots[rowIndex * columnsCount + column]`. Built once, then read-only.
public final class FlatResultStore: @unchecked Sendable {

    let arena: FieldArena
    let columnsCount: Int
    let slots: [FieldSlot]
    init(arena: FieldArena, columnsCount: Int, slots: [FieldSlot]) {
        self.arena = arena
        self.columnsCount = columnsCount
        self.slots = slots
    }
    func field(rowIndex: Int, column: Int) -> GenericField {
        let slot = slots[rowIndex * columnsCount + column]
        if slot.isNull { return .init(value: nil) }
        return .init(arena: arena, offset: slot.offset, length: slot.length)
    }
    func materializeRow(_ rowIndex: Int) -> [GenericField] {
        var fields: [GenericField] = []
        fields.reserveCapacity(columnsCount)
        let base = rowIndex * columnsCount
        for column in 0..<columnsCount {
            let slot = slots[base + column]
            fields.append(slot.isNull ? .init(value: nil) : .init(arena: arena, offset: slot.offset, length: slot.length))
        }
        return fields
    }

}

/// The cells of a single row. Backed either by a shared ``FlatResultStore`` (the
/// read path — no allocation, no per-field ARC) or, once any cell is written, by
/// an owned `[GenericField]` copied out of the store. Behaves like a mutable
/// array of ``GenericField`` so existing `row.data[i]` call sites are unchanged.
public struct FieldsView: RandomAccessCollection, MutableCollection, @unchecked Sendable {
    enum Backing {
        case shared(FlatResultStore, rowIndex: Int)
        case owned([GenericField])
    }

    var backing: Backing
    init(shared store: FlatResultStore, rowIndex: Int) {
        self.backing = .shared(store, rowIndex: rowIndex)
    }
    public init(_ fields: [GenericField]) {
        self.backing = .owned(fields)
    }

    public var startIndex: Int { 0 }

    public var endIndex: Int {
        switch backing {
        case .shared(let store, _): return store.columnsCount
        case .owned(let fields): return fields.count
        }
    }

    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }
    public subscript(position: Int) -> GenericField {
        get {
            switch backing {
            case .shared(let store, let rowIndex):
                return store.field(rowIndex: rowIndex, column: position)
            case .owned(let fields):
                return fields[position]
            }
        }
        set {
            switch backing {
            case .shared(let store, let rowIndex):
                // First write to a shared row copies it out of the store.
                var fields = store.materializeRow(rowIndex)
                fields[position] = newValue
                backing = .owned(fields)
            case .owned(var fields):
                // Drop the enum's reference first so `fields` is uniquely
                // referenced and the assignment mutates in place.
                backing = .owned([])
                fields[position] = newValue
                backing = .owned(fields)
            }
        }
    }

}

public struct GenericRow: @unchecked Sendable, Identifiable {

    public typealias ID = Int

    public let id: ID
    public var data: FieldsView

    /// Builds a row that owns its fields (used for inserted/edited rows and mocks).
    public init(id: ID, data: [GenericField]) {
        self.id = id
        self.data = FieldsView(data)
    }

    /// Builds a lightweight view onto `store` — no per-row cell allocation.
    init(id: ID, store: FlatResultStore, rowIndex: Int) {
        self.id = id
        self.data = FieldsView(shared: store, rowIndex: rowIndex)
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
