//
//  RunOutcome.swift
//  DataEngine
//

import Foundation

// MARK: - One statement

/// What became of one statement of a script.
public enum StatementDisposition: Sendable {

    case succeeded(ExecutionOutcome)

    case failed(QueryError)

    /// The driver never reached it, because an earlier statement stopped the run. Why it
    /// stopped is a property of the run and lives on ``RunOutcome/termination`` — there
    /// is only ever one reason, and repeating it per statement is how a screen ends up
    /// saying the same thing two hundred thousand times.
    case skipped

}

public extension StatementDisposition {

    var outcome: ExecutionOutcome? {
        if case .succeeded(let outcome) = self { outcome } else { nil }
    }

    var error: QueryError? {
        if case .failed(let error) = self { error } else { nil }
    }

    /// Whether this statement produced a table. False for a write, a DDL, a failure and
    /// a skip alike — so it is also the test for "is there anything here to put in a
    /// grid", which is what decides whether a slot pays for a result at all.
    var hasRows: Bool {
        guard case .succeeded(let outcome) = self else { return false }

        return !outcome.isCommand && !outcome.columns.isEmpty
    }

}

/// One statement's place in the run and what came of it.
///
/// Addressed by ordinal and nothing else. The driver reports results in order and does
/// not say which *text* produced each one — libpq hands back `PGresult`s, not offsets —
/// and the app deliberately does not split the script to find out (see
/// `docs/multi-statement-results.md`, rule A2). "Statement 3" is the whole of a
/// result's identity.
public struct StatementOutcome: Sendable {

    /// Zero-based, in the order the driver reported.
    public let index: Int

    public let disposition: StatementDisposition

    public init(index: Int, disposition: StatementDisposition) {
        self.index = index
        self.disposition = disposition
    }

}

// MARK: - The run

/// Counts for a whole run, whatever its size.
///
/// The one thing that survives at any scale: `O(1)` to update per statement, never
/// dropped, and the only account of a run whose per-statement detail has been capped
/// away. A pasted dump ends as a `RunSummary` and a handful of failures.
public struct RunSummary: Sendable, Equatable {

    public var total = 0

    public var succeeded = 0

    public var failed = 0

    public var skipped = 0

    /// Statements that produced a table. Distinct from ``succeeded`` because it is a
    /// different question: two hundred `INSERT`s all succeed and none of them is worth a
    /// grid.
    public var rowReturning = 0

    /// Index of the first statement that failed, which is where the run stopped unless
    /// it was cancelled.
    public var firstFailure: Int?

    public init() {}

    /// Whether the run has more than one statement to talk about — the test the UI uses
    /// to decide whether there is a strip to draw at all.
    public var isMultiStatement: Bool { total > 1 }

}

/// One run of one request: every statement's outcome the collector kept, the counts for
/// all of them, and how the run ended.
public struct RunOutcome: Sendable {

    /// Counts covering every statement, including those `statements` no longer holds.
    public let summary: RunSummary

    /// Per-statement detail, oldest first — **capped**, and so not necessarily one entry
    /// per statement. See ``RunCollector``. Read ``summary`` for anything that has to be
    /// true of the whole run.
    public let statements: [StatementOutcome]

    public let termination: Termination

    /// Wall time for the whole run, and the driver's own figures where the last
    /// statement reported any.
    public let statistics: ExecutionStatistics

    public init(
        summary: RunSummary,
        statements: [StatementOutcome],
        termination: Termination,
        statistics: ExecutionStatistics
    ) {
        self.summary = summary
        self.statements = statements
        self.termination = termination
        self.statistics = statistics
    }

}

public extension RunOutcome {

    enum Termination: Sendable, Equatable {

        /// Every statement ran.
        case completed

        /// A statement failed and the run stopped there.
        case failed(at: Int, rollback: Rollback)

        /// The user stopped it, or the task was cancelled.
        case cancelled(at: Int, rollback: Rollback)

    }

    /// What became of the statements *before* the one that stopped the run.
    ///
    /// A run-level fact because it has one cause and applies to a contiguous prefix.
    /// Stated once, above the results — never per statement.
    enum Rollback: Sendable, Equatable {

        /// Each statement committed on its own, so what succeeded is still there.
        /// MySQL, SQLite, DuckDB.
        case none

        /// The engine ran the whole request as one transaction and undid all of it.
        /// Postgres and Redshift over the simple query protocol — see
        /// ``TransactionSupport/implicitPerRequest``.
        case wholeScript

        /// The script contains its own `BEGIN`/`COMMIT`, which suppresses the implicit
        /// wrapper on the engines that have one — so a committed prefix may well have
        /// survived, and an uncommitted one will not have.
        ///
        /// Deliberately not resolved further. Working out which statements fell inside
        /// which transaction is a parser, and the alternative to saying "unknown" is not
        /// saying something more precise, it is saying something confident and wrong.
        case unknown

    }

    /// The last statement's outcome, whatever kind it was — **exactly** what
    /// `Session.execute` returns for the same request, and so the accessor for anything
    /// that wants the single answer a run used to have.
    ///
    /// A trailing write wins over an earlier `SELECT` here. That is not an oversight: it
    /// is what libpq has always done and what the drivers preserved deliberately, on the
    /// grounds that what a script's *last* statement did is the answer, whether or not it
    /// was a query. Anything wanting the last **table** wants ``lastRowReturning``, and
    /// the two are different questions.
    var finalOutcome: ExecutionOutcome? {
        statements.last { $0.disposition.outcome != nil }?.disposition.outcome
    }

    /// The last statement that produced a table.
    ///
    /// What a strip selects by default: a run ending in three `INSERT`s should still open
    /// on the `SELECT` before them rather than on a checkmark, because the rows are the
    /// thing the user has to look at and the writes have already said all they have to
    /// say in one line each.
    var lastRowReturning: StatementOutcome? {
        statements.last { $0.disposition.hasRows }
    }

    /// The index the run stopped at, or nil when it ran to the end.
    var stoppedAt: Int? { termination.stoppedAt }

    var rollback: Rollback { termination.rollback }

}

public extension RunOutcome.Termination {

    /// The index the run stopped at, or nil when it ran to the end.
    var stoppedAt: Int? {
        switch self {
        case .completed: nil
        case .failed(let index, _), .cancelled(let index, _): index
        }
    }

    var rollback: RunOutcome.Rollback {
        switch self {
        case .completed: .none
        case .failed(_, let rollback), .cancelled(_, let rollback): rollback
        }
    }

    /// Whether it stopped because something went wrong, as opposed to being called off or
    /// simply ending. Kept apart from ``stoppedAt`` because a cancelled run also has an
    /// index and is not a failure.
    var didFail: Bool {
        if case .failed = self { true } else { false }
    }

}

public extension RunOutcome.Rollback {

    /// What a run that stopped partway did to the statements before it.
    ///
    /// Derived rather than declared, from two facts the app already holds: whether the
    /// engine makes a request a transaction, and whether the script took transactions
    /// into its own hands. `TransactionSupport` already carries the first — Postgres and
    /// Redshift declare ``TransactionSupport/implicitPerRequest`` and say in so many
    /// words that a failing statement rolls the message back entirely — so nothing new
    /// needs declaring for it.
    ///
    /// - Parameter sql: the script as sent, or nil for a native request. Scanned only
    ///   for whether transaction control appears in it at all, which is a keyword check
    ///   the splitter already does.
    static func forStoppedRun(
        capabilities: EngineCapabilities,
        sql: String?
    ) -> RunOutcome.Rollback {
        guard capabilities.transactions == .implicitPerRequest else { return .none }

        guard let sql else { return .wholeScript }

        return StatementSplitter.containsTransactionControl(sql, escaping: capabilities.stringEscaping)
            ? .unknown
            : .wholeScript
    }

}

// MARK: - Reporting

/// What a driver says while a run is in progress.
///
/// Generalises the `onPartial` channel, which could only describe rows and could only
/// describe them for one statement. Drivers **report and never accumulate**: a script of
/// two hundred thousand statements must not fill the driver's memory with outcomes
/// before anything has had the chance to decide which of them are worth keeping. What to
/// keep is ``RunCollector``'s decision, one layer up.
public enum RunEvent: Sendable {

    /// Rows from the statement at `index`, still in flight.
    case partial(index: Int, PartialResult)

    /// The statement at `index` finished, well or badly.
    case statement(StatementOutcome)

}
