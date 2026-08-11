//
//  ReferenceEngine.swift
//  DataEngineTestKit
//

import Foundation
import DataEngine

/// An engine with no database behind it.
///
/// Two jobs. It is the worked example of what ``Session`` expects — a driver author
/// reads this before writing a real one — and it is how the app layer is tested
/// without a server: a connection whose capabilities are whatever a test needs, that
/// answers instantly and identically every time.
///
/// It takes a small SQL-shaped language rather than real SQL:
///
/// - `SELECT n` — *n* rows of the fixture columns, default ``defaultRowCount``.
/// - `FAIL message` — throws, for exercising the error path.
/// - anything else — treated as a write and answered with a command summary.
public struct ReferenceEngine: DatabaseEngine {

    public static let identifier: EngineIdentifier = "reference"

    public static let defaultRowCount = 100

    public let descriptor: EngineDescriptor

    /// - Parameter capabilities: what sessions from this engine will report. The
    ///   reason the type is parameterised at all — a test that needs a read-only
    ///   connection, or a metered one, or one that pages, builds it here.
    public init(capabilities: EngineCapabilities = .localDatabase) {
        self.descriptor = EngineDescriptor(
            id: Self.identifier,
            displayName: "Reference",
            badge: "REF",
            catalog: .flat,
            capabilities: capabilities,
            settings: SettingsSchema(sections: [
                .init("Fixture", fields: [
                    .init("rowCount", label: "Rows", kind: .number(default: Self.defaultRowCount))
                ])
            ]),
            executionModel: .concurrent
        )
    }

    public func makeSession(_ settings: SettingsValues) async throws(QueryError) -> any Session {
        try validate(settings)

        return ReferenceSession(
            capabilities: descriptor.capabilities,
            defaultRowCount: settings.int("rowCount", default: Self.defaultRowCount)
        )
    }

}

// MARK: - Columns

public extension ReferenceEngine {

    /// The fixture's columns, chosen to exercise the parts of the API that are easy to
    /// get wrong: a nullable column so a NULL cannot be confused with an empty string,
    /// and a composite one so the JSON encoding path is covered without a warehouse.
    static let columns: [ColumnDescriptor] = [
        .scalar(id: 0, name: "id", typeName: "BIGINT", kind: .integer, origin: .path(CatalogPath("fixture"))),
        .scalar(id: 1, name: "label", typeName: "TEXT", kind: .text, origin: .path(CatalogPath("fixture"))),
        .scalar(id: 2, name: "optional", typeName: "TEXT", kind: .text, origin: .path(CatalogPath("fixture")), isNullable: true),
        ColumnDescriptor(
            id: 3,
            name: "payload",
            typeName: "JSON",
            shape: .record([
                .init(name: "n", shape: .scalar(.integer)),
                .init(name: "even", shape: .scalar(.boolean))
            ]),
            origin: .path(CatalogPath("fixture"))
        )
    ]

    /// Row `index`, as the four fixture columns. Deterministic, so a test can assert
    /// on a value without having produced it first.
    static func row(_ index: Int) -> [String?] {
        [
            String(index),
            "row-\(index)",
            index.isMultiple(of: 3) ? nil : "value-\(index)",
            #"{"n":\#(index),"even":\#(index.isMultiple(of: 2))}"#
        ]
    }

}

// MARK: - Session

public actor ReferenceSession: Session {

    public nonisolated let capabilities: EngineCapabilities

    private let defaultRowCount: Int

    /// Handles this session has been asked to cancel. Recorded rather than acted on —
    /// there is nothing to stop — so a test can assert that cancellation reached the
    /// session at all, which is otherwise invisible.
    public private(set) var cancelledHandles: [ExecutionHandle] = []

    init(capabilities: EngineCapabilities, defaultRowCount: Int) {
        self.capabilities = capabilities
        self.defaultRowCount = defaultRowCount
    }

    public func execute(
        _ request: QueryRequest,
        onPartial: (@Sendable (PartialResult) -> Void)?
    ) async throws(QueryError) -> ExecutionOutcome {
        try validate(request)

        guard let sql = request.sql?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw QueryError(message: "The reference engine only runs SQL.")
        }

        let startedAt = CFAbsoluteTimeGetCurrent()

        if let message = Self.failureMessage(in: sql) {
            throw QueryError(message: message)
        }

        guard let requested = Self.selectedRowCount(in: sql, default: defaultRowCount) else {
            return .command(
                .forStatement(sql, affectedRows: 1),
                statistics: statistics(since: startedAt)
            )
        }

        let rowCount = min(requested, request.rowLimit ?? requested)

        // Priced, not run. A dry run reports what it would have cost and no rows —
        // `validate` has already rejected the request if this connection is not metered.
        guard !request.isDryRun else {
            return ExecutionOutcome(
                columns: ReferenceEngine.columns,
                store: .empty,
                statistics: statistics(since: startedAt, rowCount: rowCount)
            )
        }

        if case .cursor = capabilities.pagination {
            return try await windowed(rowCount: rowCount, startedAt: startedAt)
        }

        return complete(rowCount: rowCount, startedAt: startedAt, onPartial: onPartial)
    }

    public func cancel(_ handle: ExecutionHandle) async {
        cancelledHandles.append(handle)
    }

}

private extension ReferenceSession {

    /// The whole result in one go, publishing as it fills where anyone is listening.
    func complete(
        rowCount: Int,
        startedAt: CFAbsoluteTime,
        onPartial: (@Sendable (PartialResult) -> Void)?
    ) -> ExecutionOutcome {
        let columns = ReferenceEngine.columns

        let builder = StreamingResultBuilder(
            onPartial: onPartial.map { publish in
                { store in publish(PartialResult(columns: columns, store: store)) }
            }
        )

        for index in 0..<rowCount {
            builder.appendRow(ReferenceEngine.row(index))
        }

        return ExecutionOutcome(
            columns: columns,
            store: builder.makeStore(),
            statistics: statistics(since: startedAt, rowCount: rowCount),
            delivery: .complete
        )
    }

    /// A first window plus a cursor for the rest.
    func windowed(rowCount: Int, startedAt: CFAbsoluteTime) async throws(QueryError) -> ExecutionOutcome {
        let cursor = ReferenceCursor(totalRows: rowCount, windowSize: Self.windowSize)

        // The first window comes back through the cursor too, so the growth contract
        // holds from the very first store: everything the caller ever sees for this
        // run comes out of one builder.
        let store = try await cursor.fetchNext() ?? .empty

        return ExecutionOutcome(
            columns: ReferenceEngine.columns,
            store: store,
            statistics: statistics(since: startedAt, rowCount: rowCount),
            delivery: .windowed(cursor)
        )
    }

    static let windowSize = 25

    func statistics(since startedAt: CFAbsoluteTime, rowCount: Int = 0) -> ExecutionStatistics {
        ExecutionStatistics(
            duration: CFAbsoluteTimeGetCurrent() - startedAt,
            bytesProcessed: capabilities.cost.isMetered ? rowCount * 64 : nil,
            bytesBilled: capabilities.cost.isMetered ? max(rowCount * 64, 10 * 1024 * 1024) : nil,
            handle: ExecutionHandle(UUID().uuidString)
        )
    }

    /// `SELECT n` → n. nil when the statement is not a read at all.
    static func selectedRowCount(in sql: String, default fallback: Int) -> Int? {
        let words = sql.split(whereSeparator: \.isWhitespace)

        guard words.first?.uppercased() == "SELECT" else { return nil }

        return words.dropFirst().first.flatMap { Int($0) } ?? fallback
    }

    /// `FAIL message` → the message.
    static func failureMessage(in sql: String) -> String? {
        let words = sql.split(whereSeparator: \.isWhitespace)

        guard words.first?.uppercased() == "FAIL" else { return nil }

        let message = words.dropFirst().joined(separator: " ")

        return message.isEmpty ? "Reference failure" : message
    }

}

// MARK: - Cursor

/// Hands out the rest of a windowed result.
///
/// The reference implementation of the contract in ``Cursor``: **one builder for the
/// whole run**, so every store it returns shares the segments of the one before it and
/// a row index means the same thing in all of them.
///
/// `makeStore()` is consuming and so cannot be called per window. The builder's own
/// `onPartial` is used instead — `flush()` seals what has been written and publishes a
/// store over everything so far, which is exactly the value a fetch should return.
public actor ReferenceCursor: Cursor {

    /// Latest published store. A box because the builder's callback is not isolated to
    /// this actor; nothing outside touches it, and every write happens inside a
    /// `flush()` call made from an isolated method below.
    private final class Published {
        var store: RowStore = .empty
    }

    private let totalRows: Int

    private let windowSize: Int

    private let published = Published()

    private let builder: StreamingResultBuilder

    private var deliveredRows = 0

    private var isClosed = false

    public var mayHaveMore: Bool { !isClosed && deliveredRows < totalRows }

    init(totalRows: Int, windowSize: Int) {
        self.totalRows = totalRows
        self.windowSize = windowSize

        let published = self.published
        self.builder = StreamingResultBuilder { store in published.store = store }
    }

    public func fetchNext(maximumRows: Int?) async throws(QueryError) -> RowStore? {
        guard mayHaveMore else { return nil }

        let window = min(maximumRows ?? windowSize, totalRows - deliveredRows)

        for index in deliveredRows..<(deliveredRows + window) {
            builder.appendRow(ReferenceEngine.row(index))
        }

        deliveredRows += window

        // Seals the rows just written and republishes over everything so far.
        builder.flush()

        return published.store
    }

    public func close() async {
        isClosed = true
    }

}
