//
//  RowStore.swift
//  DataEngine
//
//  Created by Illia Senchukov on 29.07.2026.
//

import Foundation

/// A cell's location within a ``RowSegment``'s arena. A negative `length` marks SQL
/// `NULL`. Packed into one flat array per segment so rows cost no per-row
/// allocation and carry no per-cell ``FieldArena`` reference.
struct FieldSlot: Sendable {

    var offset: Int

    /// Byte length, or a negative value for SQL `NULL`.
    var length: Int

    static var null: FieldSlot { .init(offset: 0, length: -1) }

    var isNull: Bool { length < 0 }

}

/// One sealed run of consecutive rows: its own arena, its own slot table.
///
/// A segment is written by a single builder on one thread, sealed, and then never
/// touched again — which is what lets a result grow while it is being read. Growth
/// appends *new* segments; it never writes into one that has been handed out. That
/// is the whole of the argument behind `@unchecked Sendable` here and on
/// ``FieldArena``, and it is why a streaming result needs no locking on the read
/// path (`docs/grid-invariants.md`, rule A6).
///
/// A segment owns whole rows, so a cell's bytes never span two of them and
/// ``GenericField`` decoding is unaffected by segmentation.
public final class RowSegment: @unchecked Sendable {

    let arena: FieldArena

    let slots: [FieldSlot]

    public let columnCount: Int

    public let rowCount: Int

    init(arena: FieldArena, slots: [FieldSlot], columnCount: Int) {
        self.arena = arena
        self.slots = slots
        self.columnCount = columnCount
        self.rowCount = columnCount > 0 ? slots.count / columnCount : 0
    }

    /// The cell at a row *within this segment*. Callers holding a global row index
    /// go through ``RowStore`` to resolve the segment first.
    func field(localRow: Int, column: Int) -> GenericField {
        guard localRow >= 0, localRow < rowCount, column >= 0, column < columnCount else {
            return .null
        }

        let slot = slots[localRow * columnCount + column]

        guard !slot.isNull else { return .null }

        return .init(arena: arena, offset: slot.offset, length: slot.length)
    }

}

/// Every cell of one result, addressed by `(row, column)`.
///
/// This is the whole of a result's row storage. There is no array of row objects
/// alongside it: a row *is* an index into this store, which is what makes "a row's
/// identity is its position" structural rather than a convention four drivers
/// happen to honour (`docs/grid-invariants.md`, rule A5).
///
/// Rows live in an ordered list of sealed ``RowSegment``s rather than one flat
/// table. A store is still immutable — `segments` is a `let` — but a *longer* store
/// can be built that shares every segment of a shorter one, which is how a result
/// streams without any published byte ever being rewritten (rule A6). The cost is
/// that a global row index must be resolved to a segment: see ``segmentIndex(for:)``.
public final class RowStore: @unchecked Sendable {

    public static let empty = RowStore(fields: [], columnCount: 0)

    public let columnCount: Int

    public let rowCount: Int

    private let backing: Backing

    private enum Backing {
        /// Sealed byte-slice segments — the ingest path, no `String` per cell.
        /// `rowStarts[i]` is the global index of segment `i`'s first row, so it is
        /// ascending and `rowStarts.count == segments.count`.
        case segments([RowSegment], rowStarts: [Int])
        /// Already-decoded cells in row-major order — mocks and string-oriented drivers.
        case fields([GenericField])
    }

    /// Builds a store over already-sealed segments. Every segment must share the
    /// same column count; the builder is what guarantees it.
    init(segments: [RowSegment], columnCount: Int) {
        self.columnCount = columnCount

        var rowStarts: [Int] = []
        rowStarts.reserveCapacity(segments.count)

        var total = 0
        for segment in segments {
            rowStarts.append(total)
            total += segment.rowCount
        }

        self.rowCount = total
        self.backing = .segments(segments, rowStarts: rowStarts)
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
        case .segments(let segments, let rowStarts):
            let index = Self.segmentIndex(for: row, rowStarts: rowStarts)

            return segments[index].field(localRow: row - rowStarts[index], column: column)

        case .fields(let fields):
            return fields[row * columnCount + column]
        }
    }

    /// The cell's value without building a `GenericRow` or a `RowFields` first —
    /// what the grid's draw path uses.
    public func value(row: Int, column: Int) -> String? {
        field(row: row, column: column).value
    }

    /// One row's cells, with its segment resolved once.
    ///
    /// The form anything reading a whole row should use. ``field(row:column:)``
    /// resolves the segment per *cell*; this resolves it per *row*, which is what
    /// keeps the search scan — O(rows × columns) and the one path where per-cell
    /// cost is visible (rule F2) — from paying for segmentation on every column.
    public func rowFields(at row: Int) -> RowFields {
        guard row >= 0, row < rowCount else {
            return RowFields([])
        }

        switch backing {
        case .segments(let segments, let rowStarts):
            let index = Self.segmentIndex(for: row, rowStarts: rowStarts)

            return RowFields(segment: segments[index], localRow: row - rowStarts[index])

        case .fields:
            // No segment to resolve, and no slice to copy: indexing the flat table is
            // already direct.
            return RowFields(store: self, row: row)
        }
    }

    /// How many segments the rows are split across. `1` for a store built from
    /// already-decoded fields, which is one notional segment.
    var segmentCount: Int {
        switch backing {
        case .segments(let segments, _): segments.count
        case .fields: 1
        }
    }

    /// The rows of one segment, as a range of global indices.
    ///
    /// What bulk readers — the search scan, CSV export — should iterate: walking
    /// segments resolves the row-to-segment lookup once per segment rather than once
    /// per row, so reading a whole result is cheaper than it was under flat indexing
    /// rather than dearer.
    func rowRange(ofSegment index: Int) -> Range<Int> {
        switch backing {
        case .segments(let segments, let rowStarts):
            guard segments.indices.contains(index) else { return 0..<0 }

            let start = rowStarts[index]

            return start..<(start + segments[index].rowCount)

        case .fields:
            return index == 0 ? 0..<rowCount : 0..<0
        }
    }

    /// Index of the segment holding `row`: the last one whose start is `<= row`.
    ///
    /// Segments are variable length — a slow stream seals one on a deadline rather
    /// than on a row count — so this is a search rather than a division. It runs
    /// once per random cell access (the draw path, ~200 cells a frame) and once per
    /// row for anything reading rows whole, against a small, ascending, entirely
    /// cache-resident array.
    private static func segmentIndex(for row: Int, rowStarts: [Int]) -> Int {
        var low = 0
        var high = rowStarts.count - 1

        while low < high {
            // Biased high: we want the last start `<= row`, so the midpoint must be
            // able to reach `high` or the loop cannot terminate.
            let mid = (low + high + 1) / 2

            if rowStarts[mid] <= row {
                low = mid
            } else {
                high = mid - 1
            }
        }

        return low
    }

}

/// The cells of a single row, as a collection.
///
/// Backed either by a resolved ``RowSegment`` position (no allocation, no per-cell
/// ARC, no repeated segment lookup) or by an owned array for rows that have no place
/// in a result — an inserted row, a mock. Read-only in both cases: a result is what
/// the database returned.
public struct RowFields: RandomAccessCollection, @unchecked Sendable {

    enum Backing {
        /// A row of a segmented store, with its segment already resolved — so reading
        /// the row's cells costs no further lookups.
        case segment(RowSegment, localRow: Int)
        /// A row of a flat, already-decoded store. Indexing it is direct, so there is
        /// nothing to resolve and nothing to copy.
        case flat(RowStore, row: Int)
        /// An owned array for rows that have no place in a result — an inserted row,
        /// a mock.
        case owned([GenericField])
    }

    let backing: Backing

    init(segment: RowSegment, localRow: Int) {
        self.backing = .segment(segment, localRow: localRow)
    }

    init(store: RowStore, row: Int) {
        self.backing = .flat(store, row: row)
    }

    public init(_ fields: [GenericField]) {
        self.backing = .owned(fields)
    }

    public var startIndex: Int { 0 }

    public var endIndex: Int {
        switch backing {
        case .segment(let segment, _): segment.columnCount
        case .flat(let store, _): store.columnCount
        case .owned(let fields): fields.count
        }
    }

    public func index(after i: Int) -> Int { i + 1 }

    public func index(before i: Int) -> Int { i - 1 }

    public subscript(position: Int) -> GenericField {
        switch backing {
        case .segment(let segment, let localRow):
            segment.field(localRow: localRow, column: position)

        case .flat(let store, let row):
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
        self.data = store.rowFields(at: id)
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
