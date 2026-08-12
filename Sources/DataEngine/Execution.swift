//
//  Execution.swift
//  DataEngine
//

import Foundation

// MARK: - Request

/// A query an engine has not been asked to run yet.
///
/// A value rather than a string, because a string is only enough for the engines that
/// take SQL. Everything else about a run that is not the query itself — what it may
/// cost, how long it may take, whether it should be priced instead of executed — is
/// also here, so a call site states its intent once instead of the driver inferring
/// it from context it does not have.
public struct QueryRequest: Sendable {

    public enum Body: Sendable {

        case sql(String)

        /// An engine's own query form, for a store that does not take SQL.
        case native(any NativeQuery)

    }

    public var body: Body

    /// A ceiling the driver should push down into the query where it can.
    ///
    /// A hint rather than a promise: an engine that cannot express it returns
    /// everything, and the caller is not entitled to assume it was applied. It exists
    /// so `SELECT * FROM events` against a metered engine does not have to mean
    /// "scan the fact table" before anyone has decided that is what they want.
    public var rowLimit: Int?

    /// Abandon the run after this long. Distinct from task cancellation: this is what
    /// the *server* is told, where the engine supports telling it.
    public var deadline: Duration?

    /// Price the query instead of running it.
    ///
    /// The only honest way to put a number in front of someone before they spend it —
    /// BigQuery's dry run reports bytes to be scanned without scanning them. An engine
    /// that cannot estimate rejects the request rather than silently running it, which
    /// is why this is a request field and not an optional extra method: a driver that
    /// ignored it would bill for a question.
    public var isDryRun: Bool

    /// Run every statement in this request as one transaction, or none of them.
    ///
    /// For a request the caller has planned as a unit — an apply, which turns a screen
    /// full of edits into a script and has no way to describe "the first nine landed".
    /// Without it a failure halfway through leaves the database holding some of the
    /// edits while the app still holds all of them, and applying again re-runs the
    /// statements that already succeeded: an `UPDATE` survives that, an `INSERT` becomes
    /// a duplicate row.
    ///
    /// A request field rather than SQL the caller writes itself, because `BEGIN` in a
    /// string is not a transaction — the rollback is the hard half, it has to reach the
    /// same connection the statements ran on, and only the driver still knows which one
    /// that was. An engine that cannot honour this rejects the request rather than
    /// running it unprotected; see ``TransactionSupport``.
    public var isAtomic: Bool

    public init(
        _ body: Body,
        rowLimit: Int? = nil,
        deadline: Duration? = nil,
        isDryRun: Bool = false,
        isAtomic: Bool = false
    ) {
        self.body = body
        self.rowLimit = rowLimit
        self.deadline = deadline
        self.isDryRun = isDryRun
        self.isAtomic = isAtomic
    }

    public init(sql: String, rowLimit: Int? = nil, isAtomic: Bool = false) {
        self.init(.sql(sql), rowLimit: rowLimit, isAtomic: isAtomic)
    }

    /// The SQL this request carries, or nil for a native one. For the shared machinery
    /// that only knows how to reason about SQL — statement splitting, write detection.
    public var sql: String? {
        if case .sql(let sql) = body { sql } else { nil }
    }

}

/// An engine-native query for a store that does not speak SQL.
public protocol NativeQuery: Sendable {

    /// A one-line rendering for history, the tab title and error messages.
    var summary: String { get }

}

// MARK: - Identity

/// The engine's own name for a run in progress.
///
/// What `.token` cancellation is addressed to, and it is deliberately not tied to a
/// connection: a BigQuery job is cancelled by id from anywhere, and by the time the
/// user presses stop there may be no connection left to cancel it on.
public struct ExecutionHandle: Sendable, Hashable {

    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

}

// MARK: - Statistics

/// What the run cost, as far as the engine reports it.
///
/// Every field but `duration` is optional and stays nil where the engine says nothing.
/// A nil is not a zero and must never be shown as one — "scanned no bytes" and "does
/// not report bytes" are different claims, and only one of them is true of SQLite.
public struct ExecutionStatistics: Sendable {

    /// Wall time as the driver measured it, which is closer than anything the caller
    /// can time from outside.
    public var duration: TimeInterval

    /// Bytes the engine read to answer the query.
    public var bytesProcessed: Int?

    /// Bytes the engine will charge for, which is not always what it read — most
    /// warehouses round up to a minimum per query.
    public var bytesBilled: Int?

    /// The run's server-side identity, where it has one. Also what the user quotes
    /// into a support ticket.
    public var handle: ExecutionHandle?

    public init(
        duration: TimeInterval,
        bytesProcessed: Int? = nil,
        bytesBilled: Int? = nil,
        handle: ExecutionHandle? = nil
    ) {
        self.duration = duration
        self.bytesProcessed = bytesProcessed
        self.bytesBilled = bytesBilled
        self.handle = handle
    }

}

// MARK: - Results

/// Rows from a run still in flight, with the columns they belong to.
///
/// Genuinely `Sendable`, unlike the `QueryResult` this replaces on the partial path:
/// `[ColumnDescriptor]` is a value and ``RowStore`` is safe to hand across isolation
/// because a published store's segments are sealed and never rewritten
/// (`grid-invariants` rule A6).
///
/// Columns ride along on every partial rather than being delivered once. They are
/// fixed before the first row, so this is a retain rather than a copy — and it means
/// a caller can build its grid from the first partial without waiting for the run to
/// return.
public struct PartialResult: Sendable {

    public let columns: [ColumnDescriptor]

    public let store: RowStore

    public init(columns: [ColumnDescriptor], store: RowStore) {
        self.columns = columns
        self.store = store
    }

}

/// Whether the caller has been given everything, or only the first window.
public enum ResultDelivery: Sendable {

    /// Every row the query will ever produce is in the outcome.
    case complete

    /// The outcome holds the first window. Further rows exist and arrive only when
    /// asked for.
    case windowed(any Cursor)

    public var cursor: (any Cursor)? {
        if case .windowed(let cursor) = self { cursor } else { nil }
    }

}

/// One finished execution.
public struct ExecutionOutcome: Sendable {

    public let columns: [ColumnDescriptor]

    public let store: RowStore

    /// Set when the statement returned no result set — a write, a DDL. Mutually
    /// exclusive with having columns in practice; nothing enforces it, because the
    /// only way to enforce it would be to make one of them unrepresentable and both
    /// are legitimately empty for a statement that did nothing.
    public let command: CommandSummary?

    public let statistics: ExecutionStatistics

    public let delivery: ResultDelivery

    public var rowCount: Int { store.rowCount }

    public var isCommand: Bool { command != nil }

    /// Row cursors, produced on demand — see ``RowsView``.
    ///
    /// For code that reads a result whole: catalog queries, charts, CSV export. The
    /// grid does not use it, and should not — it addresses cells by `(row, column)`
    /// through ``store``, because composing a cell with its pending edit is a per-cell
    /// question.
    public var rows: RowsView { RowsView(store: store) }

    public init(
        columns: [ColumnDescriptor],
        store: RowStore,
        command: CommandSummary? = nil,
        statistics: ExecutionStatistics,
        delivery: ResultDelivery = .complete
    ) {
        self.columns = columns
        self.store = store
        self.command = command
        self.statistics = statistics
        self.delivery = delivery
    }

    /// The outcome of a statement that returned no rows.
    public static func command(
        _ summary: CommandSummary,
        statistics: ExecutionStatistics
    ) -> ExecutionOutcome {
        .init(columns: [], store: .empty, command: summary, statistics: statistics)
    }

}

// MARK: - Cursors

/// The rest of a windowed result.
///
/// **A cursor owns its row builder and keeps appending to it**, so each fetch returns
/// a store covering every row fetched *so far* rather than just the new window. That
/// is not a convenience: it is what makes a page mechanically identical to a streaming
/// chunk. `EditableResult.extend(to:)` requires a longer result over the same columns
/// sharing the shorter one's segments (`grid-invariants` rule A6), and a cursor that
/// handed back detached pages would force the caller to concatenate them — copying
/// every byte already on screen, per page, and inventing a second notion of row
/// identity while it did.
///
/// So pagination needs no new invariant. Streaming and paging differ only in who
/// initiates the next window, which is the one difference that matters: a page costs
/// a round trip, and against a metered engine it costs money. That is why fetching is
/// a call rather than something the driver does on its own.
///
/// An `Actor` because it is stateful, long-lived and reachable from the main actor
/// while a fetch is in flight.
public protocol Cursor: Actor {

    /// Whether another window may exist. False is definitive; true only means the
    /// engine has not yet said otherwise, so a fetch may still come back empty.
    var mayHaveMore: Bool { get }

    /// Fetches the next window and returns a store covering everything fetched so
    /// far, or nil once exhausted.
    ///
    /// - Parameter maximumRows: a ceiling for this window. Engines that page on their
    ///   own terms round it to their own boundary rather than honouring it exactly.
    func fetchNext(maximumRows: Int?) async throws(QueryError) -> RowStore?

    /// Releases the server-side result. Idempotent; a cursor that has been exhausted
    /// or already closed does nothing.
    func close() async

}

public extension Cursor {

    func fetchNext() async throws(QueryError) -> RowStore? {
        try await fetchNext(maximumRows: nil)
    }

}
