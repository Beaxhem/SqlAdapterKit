//
//  ScriptedSession.swift
//  DataEngineTestKit
//

import Foundation
import DataEngine

/// A session that genuinely reports a script statement by statement.
///
/// ``ReferenceEngine`` declares ``ScriptReporting/lastOnly`` and inherits the protocol
/// default for ``Session/run(_:reporting:)``, which is correct and is why it is no use
/// for one particular question: **does a wrapper around a session forward the run, or
/// quietly inherit that same default?**
///
/// That question has a real answer behind it. `SSHKit.TunneledSession` forwarded
/// `capabilities` but not `run(_:reporting:)`, so an SSH-tunnelled Postgres connection
/// published a claim of `.perStatement` and delivered one statement — no statement menu,
/// and no rows streamed past the first result. Conformance would have caught it, and
/// every check in the suite passed, because a `.lastOnly` engine behind the wrapper makes
/// "reports one statement" the *correct* answer.
///
/// So this exists to be put behind a wrapper: it claims `.perStatement` and does it, and
/// anything that passes it through unchanged has to keep doing it.
///
/// Its "parser" is a split on `;`, which is exactly what no real driver here is allowed
/// to do — see `docs/multi-statement-results.md`. That is fine precisely because there is
/// no engine: there are no transaction semantics to break, and the statements are only
/// ever the test's own.
public actor ScriptedSession: Session {

    public nonisolated let capabilities: EngineCapabilities

    private let session: any Session

    /// Wraps `session`, reporting each statement of a script separately.
    ///
    /// - Parameter session: what actually answers each statement. Defaults to a
    ///   ``ReferenceEngine`` session, so the fixture's own SQL keeps working.
    public init(
        _ session: (any Session)? = nil,
        capabilities: EngineCapabilities = .scriptedDatabase
    ) {
        self.session = session ?? ReferenceSession(
            capabilities: capabilities,
            defaultRowCount: ReferenceEngine.defaultRowCount
        )
        self.capabilities = capabilities
    }

    public func execute(
        _ request: QueryRequest,
        onPartial: (@Sendable (PartialResult) -> Void)?
    ) async throws(QueryError) -> ExecutionOutcome {
        try await session.execute(request, onPartial: onPartial)
    }

    public func run(
        _ request: QueryRequest,
        reporting: (@Sendable (RunEvent) -> Void)?
    ) async throws(QueryError) -> ExecutionOutcome {
        try validate(request)

        let statements = (request.sql ?? "")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !statements.isEmpty else {
            return try await session.execute(request, onPartial: nil)
        }

        var last: ExecutionOutcome?

        for (index, statement) in statements.enumerated() {
            let outcome: ExecutionOutcome

            // Declared and then assigned: a `@Sendable` closure built inline inside a
            // typed-throws call is more than the type checker will place on its own.
            let onPartial: (@Sendable (PartialResult) -> Void)?

            if let reporting {
                onPartial = { partial in reporting(.partial(index: index, partial)) }
            } else {
                onPartial = nil
            }

            do throws(QueryError) {
                outcome = try await session.execute(
                    QueryRequest(sql: statement, sessionContext: request.sessionContext),
                    onPartial: onPartial
                )
            } catch {
                reporting?(.statement(StatementOutcome(index: index, disposition: .failed(error))))

                throw error
            }

            reporting?(.statement(StatementOutcome(index: index, disposition: .succeeded(outcome))))

            last = outcome
        }

        return last ?? .command(.init(tag: nil, affectedRows: nil), statistics: .init(duration: 0))
    }

    public func cancel(_ handle: ExecutionHandle) async {
        await session.cancel(handle)
    }

    public func flush() async throws(QueryError) {
        try await session.flush()
    }

    public func invalidate() async {
        await session.invalidate()
    }

    public func close() async {
        await session.close()
    }

}

public extension EngineCapabilities {

    /// ``localDatabase``, but claiming — and delivering — per-statement reporting.
    ///
    /// Not named `scripting`: `EngineCapabilities` already has an instance property by
    /// that name, and a static of the same name shadows it wherever the type is the
    /// contextual one — which is every `capabilities.scripting == …` in this file.
    static let scriptedDatabase = EngineCapabilities(
        mutation: .unrestricted(.all),
        scripting: .script(.perStatement),
        transactions: .explicit,
        cancellation: .connection,
        identifierFolding: .lower
    )

}
