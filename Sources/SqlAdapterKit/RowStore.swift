//
//  RowStore.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 29.07.2026.
//

import Foundation

/// A cell's location within a ``RowStore``'s arena. A negative `length` marks SQL
/// `NULL`. Packed into one flat array per result so rows cost no per-row
/// allocation and carry no per-cell ``FieldArena`` reference.
struct FieldSlot: Sendable {

    var offset: Int

    /// Byte length, or a negative value for SQL `NULL`.
    var length: Int

    static var null: FieldSlot { .init(offset: 0, length: -1) }

    var isNull: Bool { length < 0 }

}

/// Every cell of one result, addressed by `(row, column)`.
///
/// This is the whole of a result's row storage. There is no array of row objects
/// alongside it: a row *is* an index into this store, which is what makes "a row's
/// identity is its position" structural rather than a convention four drivers
/// happen to honour (`docs/grid-invariants.md`, rule A5).
///
/// Built once and then read-only, which is what keeps `@unchecked Sendable` honest
/// and lets the search scan read it concurrently from any thread.
public final class RowStore: @unchecked Sendable {

    public static let empty = RowStore(fields: [], columnCount: 0)

    public let columnCount: Int

    public let rowCount: Int

    private let backing: Backing

    private enum Backing {
        /// Byte slices into one shared arena — the ingest path, no `String` per cell.
        case arena(FieldArena, slots: [FieldSlot])
        /// Already-decoded cells in row-major order — mocks and string-oriented drivers.
        case fields([GenericField])
    }

    init(arena: FieldArena, slots: [FieldSlot], columnCount: Int) {
        self.columnCount = columnCount
        self.rowCount = columnCount > 0 ? slots.count / columnCount : 0
        self.backing = .arena(arena, slots: slots)
    }

    /// Cells in row-major order: `fields[row * columnCount + column]`.
    public init(fields: [GenericField], columnCount: Int) {
        self.columnCount = columnCount
        self.rowCount = columnCount > 0 ? fields.count / columnCount : 0
        self.backing = .fields(fields)
    }

    public func field(row: Int, column: Int) -> GenericField {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else {
            return .null
        }

        switch backing {
        case .arena(let arena, let slots):
            let slot = slots[row * columnCount + column]
            guard !slot.isNull else { return .null }

            return .init(arena: arena, offset: slot.offset, length: slot.length)

        case .fields(let fields):
            return fields[row * columnCount + column]
        }
    }

    /// The cell's value without building a `GenericRow` or a `RowFields` first —
    /// what the grid's draw path and the search scan both use.
    public func value(row: Int, column: Int) -> String? {
        field(row: row, column: column).value
    }

}

/// The cells of a single row, as a collection.
///
/// Backed either by a shared ``RowStore`` (no allocation, no per-cell ARC) or by an
/// owned array for rows that have no place in a result — an inserted row, a mock.
/// Read-only in both cases: a result is what the database returned.
public struct RowFields: RandomAccessCollection, @unchecked Sendable {

    enum Backing {
        case store(RowStore, row: Int)
        case owned([GenericField])
    }

    let backing: Backing

    init(store: RowStore, row: Int) {
        self.backing = .store(store, row: row)
    }

    public init(_ fields: [GenericField]) {
        self.backing = .owned(fields)
    }

    public var startIndex: Int { 0 }

    public var endIndex: Int {
        switch backing {
        case .store(let store, _): store.columnCount
        case .owned(let fields): fields.count
        }
    }

    public func index(after i: Int) -> Int { i + 1 }

    public func index(before i: Int) -> Int { i - 1 }

    public subscript(position: Int) -> GenericField {
        switch backing {
        case .store(let store, let row):
            store.field(row: row, column: position)

        case .owned(let fields):
            fields.indices.contains(position) ? fields[position] : .null
        }
    }

}

/// A cursor onto one row of a ``RowStore``.
///
/// Convenience for code that reads a result row by row — driver metadata queries,
/// charts, CSV export. The grid does not go through it: it addresses cells by
/// `(row, column)` directly, because composing a row with its pending edits is a
/// per-cell question, not a per-row one.
public struct GenericRow: Sendable, Identifiable {

    public typealias ID = Int

    /// The row's index in the result it came from. Positions in a *filtered view*
    /// are a different thing entirely and never appear here.
    public let id: ID

    public let data: RowFields

    /// A row that owns its cells and belongs to no result.
    public init(id: ID, data: [GenericField]) {
        self.id = id
        self.data = RowFields(data)
    }

    init(id: ID, store: RowStore) {
        self.id = id
        self.data = RowFields(store: store, row: id)
    }

}

/// A result's rows, materialized one cursor at a time.
///
/// Deliberately not an array: `[GenericRow]` cost ~32 bytes per row for information
/// entirely derivable from the store and an index — 32 MB on a million-row result.
public struct RowsView: RandomAccessCollection, Sendable {

    let store: RowStore

    public var startIndex: Int { 0 }

    public var endIndex: Int { store.rowCount }

    public func index(after i: Int) -> Int { i + 1 }

    public func index(before i: Int) -> Int { i - 1 }

    public subscript(position: Int) -> GenericRow {
        GenericRow(id: position, store: store)
    }

}
