//
//  Session.swift
//  DataEngine
//

import Foundation

/// One live connection to one database.
///
/// Replaces `SqlAdapter`, and differs from it in three ways that the cloud engines
/// forced and the local ones benefit from anyway:
///
/// 1. **It says what it is.** ``capabilities`` is read by the app instead of the app
///    switching on which engine this happens to be. A connection is the right scope
///    for that — a Postgres session opened on a read-only role is narrower than
///    `PostgresKit` is.
/// 2. **Cancellation lives here**, not on a pooled connection. `PQcancel` needs the
///    connection it is cancelling; `jobs.cancel` needs only an id, and by the time
///    the user presses stop there may be no connection at all.
/// 3. **A run can be windowed.** ``ExecutionOutcome/delivery`` says whether the caller
///    has everything or a first page — see ``Cursor``.
///
/// The row sink stays *inside* the implementation, exactly as it does today.
/// `StreamingResultBuilder` is single-threaded by contract and is not `Sendable`, so
/// passing one in would be a hole in precisely the guarantee it exists to provide.
/// Drivers build one per run and publish through `onPartial`.
public protocol Session: Actor {

    /// What this connection can be asked to do. `nonisolated` because every caller
    /// asking it is deciding whether to offer something on screen, and none of them
    /// should have to suspend — or hop back to the main actor afterwards — to find
    /// out whether to draw a button.
    nonisolated var capabilities: EngineCapabilities { get }

    /// Runs `request`.
    ///
    /// - Parameter onPartial: called with every row read so far, at most once per
    ///   display frame, always over a row count greater than the last. A caller that
    ///   passes nil sees exactly the buffered behaviour and the driver does no clock
    ///   reads on the row path.
    ///
    ///   Only meaningful for a **single statement**. In a script a later statement can
    ///   supersede an earlier one's rows, and rows already handed over cannot be taken
    ///   back — see ``StatementSplitter/isSingleStatement(_:)``.
    ///
    /// `@concurrent` so the guarantee that a driver's work leaves the caller's
    /// executor is stated rather than inherited from today's defaults.
    @concurrent func execute(
        _ request: QueryRequest,
        onPartial: (@Sendable (PartialResult) -> Void)?
    ) async throws(QueryError) -> ExecutionOutcome

    /// Asks the server to abandon a run.
    ///
    /// Distinct from cancelling the Swift task, and the difference is what
    /// ``CancellationSupport`` exists to make visible: task cancellation stops the
    /// caller waiting, this stops the server working. Where the engine offers no way
    /// to do the second, only the first happens — and the UI must not claim otherwise,
    /// because the query is still running and still being billed.
    ///
    /// Best-effort by nature: a run that has already finished, or was never started,
    /// is not an error.
    func cancel(_ handle: ExecutionHandle) async

    /// Writes any in-memory state back to the connection's backing file.
    ///
    /// For the adapters that load a file into a table and must serialise it back after
    /// an apply — the CSV importers. Everything that queries a live database or writes
    /// through SQL inherits the no-op.
    func flush() async throws(QueryError)

    /// Releases the connection. A session is unusable afterwards.
    func close() async

}

public extension Session {

    func cancel(_ handle: ExecutionHandle) async {}

    func flush() async throws(QueryError) {}

    func close() async {}

    /// Runs `request` without asking for rows as they arrive.
    @concurrent func execute(_ request: QueryRequest) async throws(QueryError) -> ExecutionOutcome {
        try await execute(request, onPartial: nil)
    }

    /// Runs one SQL statement. The shorthand the catalog providers use, where the
    /// query is a fixed string and the result is a handful of rows.
    @concurrent func execute(sql: String) async throws(QueryError) -> ExecutionOutcome {
        try await execute(QueryRequest(sql: sql), onPartial: nil)
    }

}

// MARK: - Guard rails

public extension Session {

    /// Rejects a request the connection's own capabilities say it cannot serve.
    ///
    /// Called by drivers at the top of `execute`. It exists because a capability that
    /// is only ever read by the UI is a documentation comment: the grid not drawing an
    /// editor is what *usually* stops a write, but nothing stops a saved query, a
    /// starter snippet or the command palette from sending one anyway. Refusing here
    /// makes the declaration binding, and makes it testable — see the conformance
    /// suite's capability-honesty case.
    func validate(_ request: QueryRequest) throws(QueryError) {
        if request.isDryRun, !capabilities.cost.isMetered {
            throw QueryError(message: "This connection cannot estimate a query without running it.")
        }

        guard let sql = request.sql else { return }

        if capabilities.scripting == .singleStatement, !StatementSplitter.isSingleStatement(sql) {
            throw QueryError(
                message: "This connection runs one statement at a time. Select a single statement and run it again."
            )
        }

        if capabilities.mutation == .readOnly, !StatementSplitter.isReadOnly(sql) {
            throw QueryError(message: "This connection is read-only.")
        }
    }

}
