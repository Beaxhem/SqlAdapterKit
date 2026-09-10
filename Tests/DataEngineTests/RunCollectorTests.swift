//
//  RunCollectorTests.swift
//  DataEngineTests
//

import Testing
@testable import DataEngine

/// What a run keeps, and what it is allowed to forget.
///
/// The budgets are the whole point of this type: a pasted `mysqldump` is two hundred
/// thousand statements, and a collector that kept an outcome for each of them would be
/// the difference between a feature and a hang. So the cases below care less about the
/// happy path than about what survives the caps — the counts, always, and the failures,
/// always.
struct RunCollectorTests {

    // MARK: - Fixtures

    private static func rows(_ count: Int) -> ExecutionOutcome {
        let builder = StreamingResultBuilder()

        for index in 0..<count {
            let bytes = Array("\(index)".utf8)

            bytes.withUnsafeBytes { builder.appendValue($0.baseAddress!, length: $0.count) }
            builder.finishRow()
        }

        return ExecutionOutcome(
            columns: [ColumnDescriptor(id: 0, name: "n", typeName: "TEXT", shape: .scalar(.text))],
            store: builder.makeStore(),
            statistics: .init(duration: 0)
        )
    }

    private static func write(_ affected: Int) -> ExecutionOutcome {
        .command(
            CommandSummary(tag: "INSERT", affectedRows: affected),
            statistics: .init(duration: 0)
        )
    }

    private static func succeeded(_ index: Int, _ outcome: ExecutionOutcome) -> StatementOutcome {
        StatementOutcome(index: index, disposition: .succeeded(outcome))
    }

    private static let statistics = ExecutionStatistics(duration: 0)

    // MARK: - Counting

    @Test("counts every statement, whatever it keeps")
    func countsEverything() {
        let collector = RunCollector(detailLimit: 4, resultBudget: 2)

        for index in 0..<50 {
            collector.record(Self.succeeded(index, Self.write(1)))
        }

        let outcome = collector.finish(termination: .completed, statistics: Self.statistics)

        #expect(outcome.summary.total == 50)
        #expect(outcome.summary.succeeded == 50)
        #expect(outcome.summary.rowReturning == 0)
        // The counts are exact at any size; the detail is not, and that is the trade.
        #expect(outcome.statements.count == 4)
    }

    @Test("a write is not a row-returning statement")
    func writesAreNotResults() {
        let collector = RunCollector()

        collector.record(Self.succeeded(0, Self.rows(3)))
        collector.record(Self.succeeded(1, Self.write(7)))

        let summary = collector.summary

        #expect(summary.succeeded == 2)
        #expect(summary.rowReturning == 1)
    }

    @Test("a SELECT that matched nothing still returns rows")
    func emptyResultIsStillAResult() {
        let collector = RunCollector()

        // Columns and no rows is a truthful account of a query that matched nothing, and
        // it is a table — it must not be folded in with the writes.
        collector.record(Self.succeeded(0, Self.rows(0)))

        #expect(collector.summary.rowReturning == 1)
    }

    // MARK: - Failures

    @Test("a failure is kept past every budget")
    func failuresSurviveTheCaps() {
        let collector = RunCollector(detailLimit: 2, resultBudget: 1)

        for index in 0..<200 {
            collector.record(Self.succeeded(index, Self.write(1)))
        }

        collector.record(
            StatementOutcome(index: 200, disposition: .failed(QueryError(message: "boom")))
        )

        let outcome = collector.finish(
            termination: .failed(at: 200, rollback: .none),
            statistics: Self.statistics
        )

        // The failures are the whole reason anyone reads a large run. Dropping the only
        // interesting statement to honour a cap would be worse than having no cap.
        #expect(outcome.statements.last?.disposition.error?.message == "boom")
        #expect(outcome.summary.failed == 1)
        #expect(outcome.summary.firstFailure == 200)
    }

    @Test("the first failure is the one recorded")
    func firstFailureWins() {
        let collector = RunCollector()

        collector.record(StatementOutcome(index: 3, disposition: .failed(QueryError(message: "a"))))
        collector.record(StatementOutcome(index: 8, disposition: .failed(QueryError(message: "b"))))

        #expect(collector.summary.firstFailure == 3)
        #expect(collector.summary.failed == 2)
    }

    @Test("skipped statements are counted, not dropped from the count")
    func skipsAreCounted() {
        let collector = RunCollector()

        collector.record(Self.succeeded(0, Self.rows(1)))
        collector.record(StatementOutcome(index: 1, disposition: .failed(QueryError(message: "x"))))
        collector.record(StatementOutcome(index: 2, disposition: .skipped))
        collector.record(StatementOutcome(index: 3, disposition: .skipped))

        let summary = collector.summary

        // "2 of 4 statements ran" is a different claim from "the script had 2
        // statements", and only the count can tell them apart.
        #expect(summary.total == 4)
        #expect(summary.skipped == 2)
    }

    // MARK: - The result budget

    @Test("results past the budget keep their statement and lose their rows")
    func releasesRowsPastTheBudget() {
        let collector = RunCollector(detailLimit: 100, resultBudget: 2)

        for index in 0..<5 {
            collector.record(Self.succeeded(index, Self.rows(10)))
        }

        let outcome = collector.finish(termination: .completed, statistics: Self.statistics)

        #expect(outcome.summary.rowReturning == 5)
        #expect(outcome.statements.count == 5)

        let retained = outcome.statements.filter { $0.disposition.hasRows }

        #expect(retained.count == 2)
        #expect(retained.allSatisfy { $0.disposition.outcome?.rowCount == 10 })

        // A released result is still a success — it says what it was and how long it
        // took, and reports no columns so nothing mistakes it for a query that returned
        // nothing.
        let released = outcome.statements.filter { !$0.disposition.hasRows }

        #expect(released.count == 3)
        #expect(released.allSatisfy { $0.disposition.outcome != nil })
        #expect(released.allSatisfy { $0.disposition.outcome?.columns.isEmpty == true })
    }

    @Test("the detail limit bounds the entries a run of results keeps")
    func detailLimitBoundsResultsToo() {
        let collector = RunCollector(detailLimit: 3, resultBudget: 2)

        for index in 0..<300 {
            collector.record(Self.succeeded(index, Self.rows(5)))
        }

        let outcome = collector.finish(termination: .completed, statistics: Self.statistics)

        // Three hundred `SELECT`s is a different problem from three hundred statements,
        // and capping the rows alone would still leave three hundred entries behind.
        #expect(outcome.statements.count == 3)
        #expect(outcome.summary.total == 300)
        #expect(outcome.summary.rowReturning == 300)
    }

    // MARK: - Shape

    @Test("a one-statement run is not a multi-statement run")
    func singleStatementIsNotAStrip() {
        let collector = RunCollector()

        collector.record(Self.succeeded(0, Self.rows(4)))

        #expect(!collector.summary.isMultiStatement)

        collector.record(Self.succeeded(1, Self.rows(4)))

        #expect(collector.summary.isMultiStatement)
    }

    @Test("a trailing write is the final outcome, and the SELECT before it is the last table")
    func finalOutcomeAndLastTableAreDifferentQuestions() {
        let collector = RunCollector()

        collector.record(Self.succeeded(0, Self.rows(1)))
        collector.record(Self.succeeded(1, Self.rows(9)))
        collector.record(Self.succeeded(2, Self.write(2)))

        let outcome = collector.finish(termination: .completed, statistics: Self.statistics)

        // What `Session.execute` returns, unchanged: libpq has always let a trailing
        // command win over an earlier SELECT, and the drivers preserved that on purpose.
        #expect(outcome.finalOutcome?.isCommand == true)
        #expect(outcome.finalOutcome?.command?.affectedRows == 2)

        // What a strip opens on, which is the other question: a run ending in writes
        // should still show the rows rather than a checkmark.
        #expect(outcome.lastRowReturning?.index == 1)
        #expect(outcome.lastRowReturning?.disposition.outcome?.rowCount == 9)
    }

    @Test("partials are not statements")
    func partialsAreIgnored() {
        let collector = RunCollector()

        collector.record(
            .partial(index: 0, PartialResult(columns: [], store: .empty))
        )

        #expect(collector.summary.total == 0)
    }

}

// MARK: - Rollback

/// What a stopped run says became of the statements before it.
///
/// Derived from two facts the app already holds rather than declared, so these cases are
/// really about not claiming more than is known.
struct RollbackTests {

    private static func capabilities(_ transactions: TransactionSupport) -> EngineCapabilities {
        EngineCapabilities(
            mutation: .unrestricted(.all),
            scripting: .script(.perStatement),
            transactions: transactions
        )
    }

    @Test("an engine that commits per statement rolls nothing back")
    func independentStatements() {
        let rollback = RunOutcome.Rollback.forStoppedRun(
            capabilities: Self.capabilities(.explicit),
            sql: "INSERT INTO t VALUES (1); BOOM;"
        )

        // MySQL and SQLite autocommit each statement, so what succeeded is still there.
        #expect(rollback == .none)
    }

    @Test("an implicit per-request transaction takes the whole script with it")
    func implicitTransaction() {
        let rollback = RunOutcome.Rollback.forStoppedRun(
            capabilities: Self.capabilities(.implicitPerRequest),
            sql: "INSERT INTO t VALUES (1); BOOM;"
        )

        #expect(rollback == .wholeScript)
    }

    @Test("a script with its own transaction control is not claimed either way")
    func explicitControlIsUnknown() {
        let rollback = RunOutcome.Rollback.forStoppedRun(
            capabilities: Self.capabilities(.implicitPerRequest),
            sql: "BEGIN; INSERT INTO t VALUES (1); COMMIT; BOOM;"
        )

        // An explicit BEGIN suppresses the implicit wrapper, so a committed prefix may
        // well have survived. Saying `.wholeScript` here would be confident and wrong.
        #expect(rollback == .unknown)
    }

    @Test("transaction control inside a literal is not transaction control")
    func literalsDoNotCount() {
        let rollback = RunOutcome.Rollback.forStoppedRun(
            capabilities: Self.capabilities(.implicitPerRequest),
            sql: "INSERT INTO log VALUES ('COMMIT'); BOOM;"
        )

        #expect(rollback == .wholeScript)
    }

    @Test("a native request has no SQL to inspect and gets the confident answer")
    func nativeRequest() {
        let rollback = RunOutcome.Rollback.forStoppedRun(
            capabilities: Self.capabilities(.implicitPerRequest),
            sql: nil
        )

        #expect(rollback == .wholeScript)
    }

}
