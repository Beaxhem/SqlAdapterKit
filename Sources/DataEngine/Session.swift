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

    /// Runs `request`, reporting each statement's outcome as it completes.
    ///
    /// The multi-statement entry point, and the one a tile uses. A script produces one
    /// result per statement on every engine here; what differs is whether the client
    /// library ever lets go of the intermediate ones, which is what
    /// ``ScriptReporting`` declares.
    ///
    /// The default implementation is not a stub — it is the correct behaviour for a
    /// driver that only ever sees one result, which is every ``ScriptReporting/lastOnly``
    /// and every ``ScriptingSupport/singleStatement`` engine. It runs the request the way
    /// it has always been run and reports exactly one statement outcome. A driver that
    /// can do better overrides this and reports as it drains.
    ///
    /// Note what it does **not** do: it never splits `request`. What reaches the database
    /// is byte-for-byte what reaches it today, so the engine's own transaction semantics
    /// are untouched — see `docs/multi-statement-results.md`, rule A2.
    ///
    /// - Returns: the last statement's outcome, so the return value means exactly what
    ///   ``execute(_:onPartial:)``'s does. Everything the run said along the way went to
    ///   `reporting`; a caller wanting the whole picture folds those into a
    ///   ``RunOutcome`` with a ``RunCollector``.
    ///
    /// Named `run` rather than made a third `execute` overload on purpose. Both take a
    /// closure in second position, so every existing trailing-closure call site —
    /// `session.execute(request) { partial in … }` — became ambiguous the moment the
    /// overload existed, and would have gone on doing so in each driver package as its
    /// tests were touched.
    @concurrent func run(
        _ request: QueryRequest,
        reporting: (@Sendable (RunEvent) -> Void)?
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

    /// Drops any connection this session is holding, without closing the session.
    ///
    /// The distinction from ``close()`` is the whole reason it exists: close means the
    /// user is done with this database, this means *the sockets are dead but the session
    /// is fine*. A pooled driver empties its pool and reopens on the next statement; a
    /// driver with nothing to hold does nothing.
    ///
    /// Called when the app learns something the driver cannot: the machine woke from
    /// sleep, or the network path changed because a VPN came up and the route out is not
    /// the one every open socket was bound to. In both cases the client library still
    /// believes its connections are fine, because nothing has tried to use one since.
    ///
    /// This is the cheap half of recovery and it should be preferred wherever it works.
    /// Nothing on screen changes, no catalog is refetched, no session context is lost,
    /// no SSH tunnel is re-handshaked — the next query simply opens a socket. Tearing the
    /// whole ``Host`` down and reconnecting is the expensive half, and is only needed when
    /// the session itself is gone rather than the connections underneath it.
    func invalidate() async

    /// Releases the connection. A session is unusable afterwards.
    func close() async

}

public extension Session {

    /// See the requirement. Reports the one outcome this driver can see, under index 0.
    ///
    /// The partials are forwarded under the same index, which is the honest labelling: a
    /// driver reporting a single outcome is, as far as anything above can tell, running a
    /// one-statement script.
    @concurrent func run(
        _ request: QueryRequest,
        reporting: (@Sendable (RunEvent) -> Void)?
    ) async throws(QueryError) -> ExecutionOutcome {
        // Spelled out rather than built with `Optional.map`. The nested closure that
        // produced left the type checker unable to place `@Sendable` on the inner one,
        // and it failed without a usable diagnostic; naming the type gives it nothing
        // to infer.
        let forwardPartials: (@Sendable (PartialResult) -> Void)?

        if let reporting {
            forwardPartials = { partial in reporting(.partial(index: 0, partial)) }
        } else {
            forwardPartials = nil
        }

        let outcome = try await execute(request, onPartial: forwardPartials)

        reporting?(.statement(StatementOutcome(index: 0, disposition: .succeeded(outcome))))

        return outcome
    }

    func cancel(_ handle: ExecutionHandle) async {}

    /// See the requirement. The correct behaviour for a session holding nothing that a
    /// network event could invalidate — a file-backed engine, or a driver that opens a
    /// socket per statement and keeps none between them.
    func invalidate() async {}

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

        // Refused rather than downgraded. Running an atomic request as a plain script
        // would answer the caller's question — "did this all land?" — with a yes it has
        // no grounds for, and the caller asked precisely because it cannot recover from
        // a half-applied one.
        if request.isAtomic, !capabilities.transactions.isSupported {
            throw QueryError(
                message: "This connection cannot run a group of statements as a single transaction."
            )
        }

        guard let sql = request.sql else { return }

        if capabilities.scripting == .singleStatement,
           !StatementSplitter.isSingleStatement(sql, escaping: capabilities.stringEscaping) {
            throw QueryError(
                message: "This connection runs one statement at a time. Select a single statement and run it again."
            )
        }

        if capabilities.mutation == .readOnly,
           !StatementSplitter.isReadOnly(sql, escaping: capabilities.stringEscaping) {
            throw QueryError(message: "This connection is read-only.")
        }
    }

}
