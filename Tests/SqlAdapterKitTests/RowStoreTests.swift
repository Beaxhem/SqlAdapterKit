//
//  RowStoreTests.swift
//  SqlAdapterKitTests
//

import Testing
import Foundation
@testable import SqlAdapterKit

// MARK: - Fixtures

/// Carries a value into exactly one task. Stands in for the confinement a driver gets
/// for free by holding its builder in one drain loop.
private final class SingleThreadedBox<T>: @unchecked Sendable {

    let value: T

    init(_ value: T) { self.value = value }

}

/// Feeds `rows` through a builder, splitting segments every `cellsPerSegment` cells.
///
/// Segment boundaries are invisible through the public API — that is the whole point
/// of the abstraction — so the only way to test that addressing survives them is to
/// place them deliberately.
private func makeBuilder(
    cellsPerSegment: Int,
    onPartial: ((RowStore) -> Void)? = nil
) -> StreamingResultBuilder {
    var policy = StreamingResultBuilder.Policy.default
    policy.targetCellsPerSegment = cellsPerSegment
    // Emitting is driven by the segment seals in these tests, never by the clock.
    policy.emitInterval = 0

    return StreamingResultBuilder(policy: policy, onPartial: onPartial)
}

/// Appends one row of `[String?]`, where `nil` is SQL NULL.
private func append(_ row: [String?], to builder: StreamingResultBuilder) {
    for cell in row {
        guard let cell else {
            builder.appendNull()
            continue
        }

        let bytes = Array(cell.utf8)
        if bytes.isEmpty {
            builder.appendValue([UInt8](), length: 0)
        } else {
            bytes.withUnsafeBytes { builder.appendValue($0.baseAddress!, length: $0.count) }
        }
    }

    builder.finishRow()
}

private func store(rows: [[String?]], cellsPerSegment: Int) -> RowStore {
    let builder = makeBuilder(cellsPerSegment: cellsPerSegment)

    for row in rows { append(row, to: builder) }

    return builder.makeStore()
}

/// `count` rows of `columns` columns, cell `(r, c)` spelled `"r:c"`, with every
/// seventh cell NULL so null handling is exercised across segment boundaries too.
private func sampleRows(count: Int, columns: Int) -> [[String?]] {
    (0..<count).map { row in
        (0..<columns).map { column in
            (row * columns + column) % 7 == 0 ? nil : "\(row):\(column)"
        }
    }
}

private func expectMatches(_ store: RowStore, _ rows: [[String?]], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(store.rowCount == rows.count, sourceLocation: sourceLocation)

    for (index, row) in rows.enumerated() {
        for (column, expected) in row.enumerated() {
            #expect(
                store.value(row: index, column: column) == expected,
                "cell (\(index), \(column))",
                sourceLocation: sourceLocation
            )

            #expect(
                store.rowFields(at: index)[column].value == expected,
                "rowFields (\(index), \(column))",
                sourceLocation: sourceLocation
            )
        }
    }
}

// MARK: - Addressing across segment boundaries

/// The property that matters: how rows were split must not be observable. Every
/// split from "one row per segment" to "everything in one" has to read identically.
@Test(arguments: [1, 2, 3, 5, 8, 13, 64, 1_000])
func addressingIsIndependentOfSegmentation(cellsPerSegment: Int) {
    let rows = sampleRows(count: 50, columns: 4)

    expectMatches(store(rows: rows, cellsPerSegment: cellsPerSegment), rows)
}

@Test func segmentationActuallySplits() {
    // Guards the tests above: if the policy stopped splitting they would all pass
    // trivially against a single segment.
    let builder = makeBuilder(cellsPerSegment: 4)

    for row in sampleRows(count: 50, columns: 4) { append(row, to: builder) }

    #expect(builder.rowCount == 50)

    let store = builder.makeStore()

    #expect(store.rowCount == 50)
    #expect(store.segmentCount > 1)

    // The segments partition the rows: contiguous, ascending, covering everything.
    var next = 0
    for index in 0..<store.segmentCount {
        let range = store.rowRange(ofSegment: index)

        #expect(range.lowerBound == next)
        #expect(!range.isEmpty, "an empty segment should never be sealed")

        next = range.upperBound
    }

    #expect(next == store.rowCount)
}

@Test func outOfBoundsReadsAreNullRatherThanCrashes() {
    let rows = sampleRows(count: 10, columns: 3)
    let subject = store(rows: rows, cellsPerSegment: 6)

    #expect(subject.field(row: -1, column: 0).isNull)
    #expect(subject.field(row: 10, column: 0).isNull)
    #expect(subject.field(row: 0, column: -1).isNull)
    #expect(subject.field(row: 0, column: 3).isNull)
    #expect(subject.rowFields(at: 10).isEmpty)
}

// MARK: - Shapes

@Test func emptyResultHasNoRows() {
    let subject = store(rows: [], cellsPerSegment: 4)

    #expect(subject.rowCount == 0)
    #expect(subject.field(row: 0, column: 0).isNull)
}

@Test func singleRowResult() {
    let rows: [[String?]] = [["a", nil, "c"]]

    expectMatches(store(rows: rows, cellsPerSegment: 1_000), rows)
}

/// The last segment is almost always partial — 50 rows do not divide into segments
/// of 3 — so this is the ordinary case rather than an edge one.
@Test func trailingPartialSegmentIsIncluded() {
    let rows = sampleRows(count: 50, columns: 3)
    let subject = store(rows: rows, cellsPerSegment: 9)

    #expect(subject.rowCount == 50)
    expectMatches(subject, rows)
}

@Test func emptyStringIsNotNull() {
    let rows: [[String?]] = [["", nil]]
    let subject = store(rows: rows, cellsPerSegment: 1_000)

    #expect(subject.field(row: 0, column: 0).isNull == false)
    #expect(subject.value(row: 0, column: 0) == "")
    #expect(subject.field(row: 0, column: 1).isNull)
}

/// Cells are not required to be small, and a cell that is larger than the byte budget
/// must still land whole in a segment of its own rather than being split.
@Test func cellLargerThanTheByteBudgetSurvives() {
    var policy = StreamingResultBuilder.Policy.default
    policy.segmentByteBudget = 64

    let builder = StreamingResultBuilder(policy: policy)
    let large = String(repeating: "x", count: 5_000)

    append([large, "small"], to: builder)
    append(["after", "boundary"], to: builder)

    let subject = builder.makeStore()

    #expect(subject.value(row: 0, column: 0) == large)
    #expect(subject.value(row: 0, column: 1) == "small")
    #expect(subject.value(row: 1, column: 0) == "after")
    #expect(subject.value(row: 1, column: 1) == "boundary")
}

// MARK: - Growth

/// The invariant the whole streaming design rests on: a store handed out earlier
/// keeps reporting exactly what it reported, however many rows arrive afterwards.
@Test func anEarlierStoreNeverSeesLaterRows() {
    var published: [RowStore] = []

    let builder = makeBuilder(cellsPerSegment: 4) { published.append($0) }
    let rows = sampleRows(count: 40, columns: 2)

    for row in rows { append(row, to: builder) }

    let final = builder.makeStore()

    #expect(published.count > 1, "expected several partial stores")

    for snapshot in published {
        #expect(snapshot.rowCount <= final.rowCount)

        // Every row the snapshot claims reads the same in it as in the final store.
        expectMatches(snapshot, Array(rows.prefix(snapshot.rowCount)))

        // And it cannot see past its own end.
        #expect(snapshot.field(row: snapshot.rowCount, column: 0).isNull)
    }

    expectMatches(final, rows)
}

@Test func publishedRowCountsOnlyGrow() {
    var counts: [Int] = []

    let builder = makeBuilder(cellsPerSegment: 4) { counts.append($0.rowCount) }

    for row in sampleRows(count: 40, columns: 2) { append(row, to: builder) }

    #expect(counts == counts.sorted())
    #expect(Set(counts).count == counts.count, "a store should never be published twice at the same length")
}

/// A buffered run and a streamed one must produce the same store. Sealing is not
/// conditional on anyone listening, so the two paths share one shape and the
/// segmented code cannot rot behind the streaming flag.
@Test func bufferedAndStreamedRunsAgree() {
    let rows = sampleRows(count: 40, columns: 2)

    let buffered = makeBuilder(cellsPerSegment: 4, onPartial: nil)
    for row in rows { append(row, to: buffered) }
    let bufferedStore = buffered.makeStore()

    let streamed = makeBuilder(cellsPerSegment: 4) { _ in }
    for row in rows { append(row, to: streamed) }
    let streamedStore = streamed.makeStore()

    #expect(bufferedStore.segmentCount == streamedStore.segmentCount)

    expectMatches(bufferedStore, rows)
    expectMatches(streamedStore, rows)
}

// MARK: - Concurrent reads

/// A published store is read from the draw path and the search scan while the drain
/// loop is still appending. Rows are only ever added, never rewritten, so this must
/// hold without any locking.
@Test func asnapshotIsStableWhileTheBuilderKeepsAppending() async {
    let rows = sampleRows(count: 400, columns: 3)

    // The first store the builder publishes, kept exactly as handed over — which is
    // what the grid does with it.
    nonisolated(unsafe) var snapshot: RowStore?
    let builder = makeBuilder(cellsPerSegment: 6) { store in
        if snapshot == nil { snapshot = store }
    }

    for row in rows.prefix(50) { append(row, to: builder) }

    guard let snapshot else {
        Issue.record("the builder published nothing")
        return
    }

    let expected = Array(rows.prefix(snapshot.rowCount))

    #expect(!expected.isEmpty)

    // Readers hammer the snapshot while the drain loop keeps appending — the real
    // arrangement, and it must hold with no locking anywhere.
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<4 {
            group.addTask {
                for _ in 0..<50 {
                    guard snapshot.rowCount == expected.count else { return false }

                    for (index, row) in expected.enumerated() {
                        for (column, cell) in row.enumerated() {
                            guard snapshot.value(row: index, column: column) == cell else { return false }
                        }
                    }
                }
                return true
            }
        }

        // The builder is single-threaded by contract, so it is confined to this one
        // task — exactly as a driver confines it to its drain loop. The box is what
        // says so to the compiler; the readers above never touch it, only the store
        // it already published.
        let confined = SingleThreadedBox(builder)

        group.addTask {
            for row in rows.dropFirst(50) { append(row, to: confined.value) }
            return true
        }

        for await ok in group {
            #expect(ok)
        }
    }

    #expect(snapshot.rowCount == expected.count, "the snapshot must not have grown")
    expectMatches(snapshot, expected)
}
