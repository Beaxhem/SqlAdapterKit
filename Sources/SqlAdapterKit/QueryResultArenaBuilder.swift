//
//  QueryResultArenaBuilder.swift
//  SqlAdapterKit
//

import Foundation

/// Accumulates cell bytes into a single ``FieldArena`` and a flat ``FieldSlot``
/// table, then emits ``GenericRow``s that are lightweight views onto the
/// resulting ``FlatResultStore`` — one pass, no per-row cell allocation.
///
/// Drivers copy each cell's raw bytes out of driver-owned memory as they read
/// it — mandatory for cursor-style backends like SQLite — and call
/// ``finishRow(id:)`` once per row. Because slots address the arena by index
/// rather than by pointer, they stay valid as the arena grows. No Swift `String`
/// is allocated per cell; decoding is deferred to ``GenericField/value``.
///
/// The builder owns the arena and slot table until ``makeRows()`` wraps them in
/// a `FlatResultStore`, so callers can never observe them mid-growth — which is
/// what keeps the store's `@unchecked Sendable` honest.
public final class QueryResultArenaBuilder {

    private let arena = FieldArena()
    private var slots: [FieldSlot] = []
    private var rowIDs: [Int] = []

    /// Column count, taken from the first completed row. SQL results are
    /// rectangular, so every row must match it.
    private var columnsCount = -1
    private var currentRowWidth = 0

    /// - Parameter estimatedBytes: rough total payload size, used to pre-size the
    ///   arena. Pass 0 when unknown (e.g. a cursor with no row count).
    public init(estimatedBytes: Int = 0) {
        if estimatedBytes > 0 { arena.reserveCapacity(estimatedBytes) }
    }

    /// Copy `length` raw bytes at `pointer` into the arena as one non-null cell.
    /// A `length` of 0 yields an empty (non-null) value.
    public func appendValue(_ pointer: UnsafeRawPointer, length: Int) {
        let offset = arena.append(pointer, length: length)
        slots.append(.init(offset: offset, length: length))
        currentRowWidth += 1
    }

    /// Copy a null-terminated C string into the arena as one non-null cell.
    /// The terminating NUL is not included.
    public func appendCString(_ cString: UnsafePointer<CChar>) {
        appendValue(cString, length: strlen(cString))
    }

    /// Append one SQL `NULL` cell.
    public func appendNull() {
        slots.append(.null)
        currentRowWidth += 1
    }

    /// Close the current row. Every cell appended since the previous
    /// `finishRow` becomes this row's fields, in order.
    public func finishRow(id: Int) {
        if columnsCount < 0 {
            columnsCount = currentRowWidth
        } else {
            assert(currentRowWidth == columnsCount, "SQL result rows must be rectangular")
        }
        rowIDs.append(id)
        currentRowWidth = 0
    }

    /// Finalize the store and build the row views onto it.
    public consuming func makeRows() -> [GenericRow] {
        let store = FlatResultStore(
            arena: arena,
            columnsCount: max(columnsCount, 0),
            slots: slots
        )

        var rows: [GenericRow] = []
        rows.reserveCapacity(rowIDs.count)
        for (index, id) in rowIDs.enumerated() {
            rows.append(.init(id: id, store: store, rowIndex: index))
        }
        return rows
    }

}
