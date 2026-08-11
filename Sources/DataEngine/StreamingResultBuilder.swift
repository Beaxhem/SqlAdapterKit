//
//  StreamingResultBuilder.swift
//  DataEngine
//

import Foundation

/// Accumulates cell bytes into sealed ``RowSegment``s and, optionally, hands the
/// caller a longer ``RowStore`` as the rows arrive.
///
/// Drivers copy each cell's raw bytes out of driver-owned memory as they read it —
/// mandatory for cursor-style backends like SQLite — and call ``finishRow()`` once
/// per row. Because slots address their segment's arena by index rather than by
/// pointer, they stay valid as that arena grows. No Swift `String` is allocated per
/// cell; decoding is deferred to ``GenericField/value``.
///
/// Rows are numbered by the builder, in the order they are finished. A driver
/// cannot hand out its own ids, which is what makes a row's index its identity
/// everywhere downstream.
///
/// ## Why segments
///
/// The builder never exposes the segment it is currently filling. A segment is
/// sealed — closed, never written again — before it can appear in any store handed
/// out. So a store published mid-query and the longer store published after it
/// share segment *objects* rather than copying bytes, and no published byte is ever
/// rewritten. That is what makes ``RowStore``'s and ``FieldArena``'s
/// `@unchecked Sendable` hold while a result is still growing.
///
/// ## Coalescing lives here
///
/// Not in the drivers. A driver calls the same append/finish API whether or not
/// anyone is listening; this type decides when a segment is worth sealing and when a
/// store is worth publishing. One implementation, four drivers.
///
/// Single-threaded by contract: one builder, one drain loop, one thread. ``onPartial``
/// is invoked on that thread, synchronously, and must not block it.
public final class StreamingResultBuilder {

    /// When a segment is sealed and how often a store is published.
    ///
    /// A type rather than four constants so the boundaries can be pinned in tests:
    /// segment splits are invisible through the public API by design — that is the
    /// point of the abstraction — so the only way to test that addressing survives
    /// them is to place them deliberately.
    struct Policy: Sendable {

        /// Cells per segment, aimed at rather than guaranteed — the row capacity
        /// derived from it is what is actually enforced. Sized so a segment's slot
        /// table stays in the hundreds of kilobytes for ordinary results.
        var targetCellsPerSegment = 32_768

        /// A segment seals once its arena passes this, whatever its row count.
        /// Without it a handful of large blob cells would put an unbounded arena
        /// behind one segment.
        var segmentByteBudget = 4 << 20

        /// Rows between clock reads. Keeps `CFAbsoluteTimeGetCurrent` off the per-row
        /// path (~94k reads over a 6M-row result, ~2ms) while staying responsive when
        /// rows are slow — 64 rows is a short interval precisely when arrival is slow.
        var rowsPerClockCheck = 64

        /// Minimum wall time between published stores. One display frame: publishing
        /// more often cannot show the user anything new, and costs a main-actor hop
        /// each time.
        var emitInterval: CFTimeInterval = 1.0 / 60.0

        static let `default` = Policy()

    }

    private let policy: Policy

    private var sealed: [RowSegment] = []

    private var arena = FieldArena()
    private var slots: [FieldSlot] = []
    private var segmentRowCount = 0

    /// Column count, taken from the first completed row. SQL results are
    /// rectangular, so every row must match it.
    private var columnCount = -1
    private var currentRowWidth = 0

    /// Rows per segment, derived from ``columnCount`` once it is known. Wide results
    /// get shorter segments so a segment's slot table stays a similar size either way.
    private var rowCapacity = Int.max

    public private(set) var rowCount = 0

    private var rowsSinceClockCheck = 0
    private var lastEmitAt: CFAbsoluteTime?

    /// Called with a store covering every row sealed so far, at most once per
    /// ``emitInterval``. `nil` for a buffered run, which is then exactly the old
    /// build-then-freeze behaviour with no clock reads on the row path.
    private let onPartial: ((RowStore) -> Void)?

    /// - Parameters:
    ///   - estimatedBytes: rough payload size of the first segment, used to pre-size
    ///     its arena. Pass 0 when unknown (e.g. a cursor with no row count).
    ///   - onPartial: invoked as rows arrive. Omit for a buffered run.
    public convenience init(estimatedBytes: Int = 0, onPartial: ((RowStore) -> Void)? = nil) {
        self.init(estimatedBytes: estimatedBytes, policy: .default, onPartial: onPartial)
    }

    init(estimatedBytes: Int = 0, policy: Policy, onPartial: ((RowStore) -> Void)? = nil) {
        self.policy = policy
        self.onPartial = onPartial

        if estimatedBytes > 0 { arena.reserveCapacity(min(estimatedBytes, policy.segmentByteBudget)) }
    }

    /// Copy `length` raw bytes at `pointer` into the current segment as one non-null
    /// cell. A `length` of 0 yields an empty (non-null) value.
    public func appendValue(_ pointer: UnsafeRawPointer, length: Int) {
        let offset = arena.append(pointer, length: length)
        slots.append(.init(offset: offset, length: length))
        currentRowWidth += 1
    }

    /// Copy a null-terminated C string into the current segment as one non-null cell.
    /// The terminating NUL is not included.
    public func appendCString(_ cString: UnsafePointer<CChar>) {
        appendValue(cString, length: strlen(cString))
    }

    /// Append one SQL `NULL` cell.
    public func appendNull() {
        slots.append(.null)
        currentRowWidth += 1
    }

    /// Close the current row. Every cell appended since the previous `finishRow`
    /// becomes this row's cells, in order.
    public func finishRow() {
        if columnCount < 0 {
            columnCount = currentRowWidth
            rowCapacity = max(1, policy.targetCellsPerSegment / max(columnCount, 1))
        } else {
            assert(currentRowWidth == columnCount, "SQL result rows must be rectangular")
        }

        rowCount += 1
        segmentRowCount += 1
        currentRowWidth = 0

        // Sealing happens whether or not anyone is listening, so a buffered result has
        // exactly the same internal shape as a streamed one — the segmented path
        // cannot rot behind a flag. It is also the cheaper shape outright: a 6M-row
        // result's slot table is ~480 MB, and growing *one* array to that size doubles
        // through a transient ~960 MB. Segments cap each allocation instead.
        if segmentRowCount >= rowCapacity || arena.bytes.count >= policy.segmentByteBudget {
            sealSegment()

            // The first store goes out the moment there is one, rather than waiting
            // out an interval that has not started yet: the first screenful is the
            // whole point, and the cadence only matters from the second store on.
            emit(force: lastEmitAt == nil)
            return
        }

        guard onPartial != nil else { return }

        rowsSinceClockCheck += 1

        guard rowsSinceClockCheck >= policy.rowsPerClockCheck else { return }

        rowsSinceClockCheck = 0

        // A slow stream seals on the deadline instead of on a row count, so rows
        // trickling in at a hundred a second still reach the grid promptly.
        guard isEmitDue() else { return }

        sealSegment()
        emit(force: true)
    }

    /// Publishes every row read so far, including the segment still being filled.
    ///
    /// For a run that is about to end without reaching ``makeStore()`` — a connection
    /// that died mid-drain, a statement that errored after rows. Those rows were sent
    /// by the database and read by the driver; without this they are discarded for no
    /// better reason than that they landed after the last chunk boundary, which at full
    /// speed is tens of thousands of rows.
    ///
    /// Ignores the emit interval: there is no later publication to wait for.
    public func flush() {
        sealSegment()
        emit(force: true)
    }

    /// Finalize the cell storage for a result. Seals whatever is still open, so the
    /// trailing partial segment is included.
    public consuming func makeStore() -> RowStore {
        sealSegment()

        return RowStore(segments: sealed, columnCount: max(columnCount, 0))
    }

}

private extension StreamingResultBuilder {

    /// Closes the segment being filled and starts a new one. A no-op when nothing has
    /// been written since the last seal, so an empty segment is never produced.
    func sealSegment() {
        guard segmentRowCount > 0 else { return }

        sealed.append(RowSegment(arena: arena, slots: slots, columnCount: max(columnCount, 0)))

        arena = FieldArena()
        slots = []
        segmentRowCount = 0
    }

    func isEmitDue() -> Bool {
        guard let lastEmitAt else { return true }

        return CFAbsoluteTimeGetCurrent() - lastEmitAt >= policy.emitInterval
    }

    /// Publishes a store over everything sealed so far.
    ///
    /// Only the segment list is rebuilt — a few hundred references — never a row's
    /// bytes, which stay in the segments both the old store and the new one point at.
    func emit(force: Bool) {
        guard let onPartial, !sealed.isEmpty else { return }
        guard force || isEmitDue() else { return }

        lastEmitAt = CFAbsoluteTimeGetCurrent()

        onPartial(RowStore(segments: sealed, columnCount: max(columnCount, 0)))
    }

}
