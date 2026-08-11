//
//  Conformance.swift
//  DataEngineTestKit
//

import Foundation
import DataEngine

/// One thing a session must get right.
public struct ConformanceCheck: Sendable {

    public let name: String

    public let outcome: Outcome

    public enum Outcome: Sendable, Equatable {
        case passed
        case failed(String)
        /// The session's declared capabilities put this check out of scope — a
        /// read-only connection is not asked to report a command tag.
        case notApplicable(String)
    }

    public var didPass: Bool { outcome != .failed("") && !isFailure }

    public var isFailure: Bool {
        if case .failed = outcome { true } else { false }
    }

}

public struct ConformanceReport: Sendable {

    public let checks: [ConformanceCheck]

    public var failures: [ConformanceCheck] { checks.filter(\.isFailure) }

    public var didPass: Bool { failures.isEmpty }

    /// One line per check, for a test failure message that says which one broke
    /// without the reader going back to the source.
    public var summary: String {
        checks.map { check in
            switch check.outcome {
            case .passed: "✓ \(check.name)"
            case .failed(let reason): "✗ \(check.name) — \(reason)"
            case .notApplicable(let reason): "– \(check.name) (\(reason))"
            }
        }
        .joined(separator: "\n")
    }

}

/// The statements one engine needs in order to be put through the suite.
///
/// The suite cannot write the SQL itself: `SELECT 50` is the reference engine's
/// language, `SELECT * FROM generate_series(1, 50)` is Postgres', and BigQuery wants a
/// project-qualified name. So each engine supplies its own, and the *assertions* are
/// shared — which is the part worth sharing.
public struct ConformanceFixture: Sendable {

    /// A read producing exactly `rowCount` rows.
    public var read: @Sendable (_ rowCount: Int) -> String

    /// A statement that writes and returns no result set.
    public var write: String

    /// Two statements in one string.
    public var script: String

    /// Something the engine must reject with a ``QueryError`` rather than a trap.
    public var invalid: String

    /// Index of a column the read produces at least one SQL NULL in.
    public var nullableColumnIndex: Int?

    public init(
        read: @escaping @Sendable (Int) -> String,
        write: String,
        script: String,
        invalid: String,
        nullableColumnIndex: Int? = nil
    ) {
        self.read = read
        self.write = write
        self.script = script
        self.invalid = invalid
        self.nullableColumnIndex = nullableColumnIndex
    }

    /// The fixture for ``ReferenceEngine``.
    public static let reference = ConformanceFixture(
        read: { "SELECT \($0)" },
        write: "UPDATE fixture SET label = 'x'",
        script: "SELECT 1; SELECT 2",
        invalid: "FAIL deliberate",
        nullableColumnIndex: 2
    )

}

/// What every ``Session`` must do, whatever is behind it.
///
/// Run against the reference engine, against each real driver, and against
/// ``LegacySessionBridge`` — which is what makes "the bridge is faithful" a test
/// result rather than a claim, and what stops the fifth driver rediscovering a rule
/// the first four already learned.
///
/// Reports rather than asserts, so it needs no test framework and can be run from a
/// driver package that has none.
public enum EngineConformance {

    public static func run(
        session: any Session,
        fixture: ConformanceFixture = .reference,
        rowCount: Int = 60
    ) async -> ConformanceReport {
        var checks: [ConformanceCheck] = []

        checks.append(await columnsAndShape(session, fixture, rowCount))
        checks.append(await nullsSurvive(session, fixture, rowCount))
        checks.append(await streamingIsMonotonic(session, fixture, rowCount))
        checks.append(await bufferedMatchesStreamed(session, fixture, rowCount))
        checks.append(await errorsAreReported(session, fixture))
        checks.append(await commandsReportATag(session, fixture))
        checks.append(await readOnlyRefusesWrites(session, fixture))
        checks.append(await singleStatementRefusesScripts(session, fixture))
        checks.append(await dryRunMatchesCostModel(session, fixture, rowCount))
        checks.append(await cursorTerminates(session, fixture, rowCount))

        return ConformanceReport(checks: checks)
    }

}

// MARK: - Checks

private extension EngineConformance {

    /// Columns are known, and the store agrees with them.
    ///
    /// The rectangularity half is the one that matters: every index handed out
    /// downstream — a column index in the grid, a cell address in the overlay —
    /// assumes it (`grid-invariants` rule A5), and a driver that miscounts one row
    /// corrupts every row after it rather than failing.
    static func columnsAndShape(
        _ session: any Session,
        _ fixture: ConformanceFixture,
        _ rowCount: Int
    ) async -> ConformanceCheck {
        await check("columns are reported and the store matches them") {
            let outcome = try await session.execute(sql: fixture.read(rowCount))

            guard !outcome.columns.isEmpty else {
                return .failed("a read reported no columns")
            }

            guard outcome.store.columnCount == outcome.columns.count else {
                return .failed("store has \(outcome.store.columnCount) columns, outcome reports \(outcome.columns.count)")
            }

            // Only a `.complete` delivery promises every row. A windowed one is
            // *supposed* to come back short — the outcome is the first window and the
            // rest is behind the cursor, which ``cursorTerminates`` accounts for. This
            // check asserting the full count is what a paging engine would otherwise
            // have to fail in order to behave correctly.
            switch outcome.delivery {
            case .complete:
                guard outcome.rowCount == rowCount else {
                    return .failed("asked for \(rowCount) rows, got \(outcome.rowCount)")
                }

            case .windowed:
                guard outcome.rowCount > 0 else {
                    return .failed("a windowed read returned an empty first window")
                }

                guard outcome.rowCount <= rowCount else {
                    return .failed("first window holds \(outcome.rowCount) rows, more than the \(rowCount) asked for")
                }
            }

            // Ids address the result positionally, so they must be exactly 0..<count.
            guard outcome.columns.map(\.id) == Array(0..<outcome.columns.count) else {
                return .failed("column ids are not their positions: \(outcome.columns.map(\.id))")
            }

            return .passed
        }
    }

    /// A NULL comes back as a NULL and not as an empty string.
    ///
    /// They render differently, sort differently, and mean different things in a
    /// WHERE clause. A driver that flattens one into the other is not detectably
    /// wrong until someone edits a row.
    static func nullsSurvive(
        _ session: any Session,
        _ fixture: ConformanceFixture,
        _ rowCount: Int
    ) async -> ConformanceCheck {
        await check("SQL NULL is distinguishable from an empty string") {
            guard let column = fixture.nullableColumnIndex else {
                return .notApplicable("fixture declares no nullable column")
            }

            let outcome = try await session.execute(sql: fixture.read(rowCount))

            let fields = (0..<outcome.rowCount).map { outcome.store.field(row: $0, column: column) }

            guard fields.contains(where: \.isNull) else {
                return .failed("no NULL in column \(column), so the fixture cannot test this")
            }

            guard fields.contains(where: { !$0.isNull }) else {
                return .failed("every value in column \(column) is NULL")
            }

            return .passed
        }
    }

    /// Partials grow, never shrink, never exceed the final result, and always describe
    /// the same columns.
    static func streamingIsMonotonic(
        _ session: any Session,
        _ fixture: ConformanceFixture,
        _ rowCount: Int
    ) async -> ConformanceCheck {
        await check("streamed partials grow monotonically over stable columns") {
            let recorder = PartialRecorder()

            let outcome = try await session.execute(QueryRequest(sql: fixture.read(rowCount))) { partial in
                recorder.record(partial)
            }

            let partials = recorder.partials

            guard !partials.isEmpty else {
                return .notApplicable("this session does not report rows before completion")
            }

            var previous = 0
            for partial in partials {
                guard partial.rowCount > previous else {
                    return .failed("partial went from \(previous) to \(partial.rowCount) rows")
                }

                guard partial.rowCount <= outcome.rowCount else {
                    return .failed("a partial reported \(partial.rowCount) rows, more than the final \(outcome.rowCount)")
                }

                guard partial.columnNames == outcome.columns.map(\.name) else {
                    return .failed("a partial's columns differ from the outcome's")
                }

                previous = partial.rowCount
            }

            return .passed
        }
    }

    /// Asking for rows early does not change what the rows are.
    static func bufferedMatchesStreamed(
        _ session: any Session,
        _ fixture: ConformanceFixture,
        _ rowCount: Int
    ) async -> ConformanceCheck {
        await check("a streamed run and a buffered run agree") {
            let sql = fixture.read(rowCount)

            let buffered = try await session.execute(sql: sql)
            let streamed = try await session.execute(QueryRequest(sql: sql)) { _ in }

            guard buffered.rowCount == streamed.rowCount else {
                return .failed("buffered \(buffered.rowCount) rows, streamed \(streamed.rowCount)")
            }

            guard buffered.columns.map(\.name) == streamed.columns.map(\.name) else {
                return .failed("the two runs reported different columns")
            }

            for row in 0..<min(buffered.rowCount, 8) {
                for column in 0..<buffered.columns.count {
                    let left = buffered.store.field(row: row, column: column)
                    let right = streamed.store.field(row: row, column: column)

                    guard left.isNull == right.isNull, left.value == right.value else {
                        return .failed("row \(row) column \(column) differs between the two runs")
                    }
                }
            }

            return .passed
        }
    }

    /// A rejected statement is an error, not a trap and not an empty result.
    static func errorsAreReported(
        _ session: any Session,
        _ fixture: ConformanceFixture
    ) async -> ConformanceCheck {
        await check("an invalid statement throws QueryError") {
            do {
                let outcome = try await session.execute(sql: fixture.invalid)

                return .failed("returned \(outcome.rowCount) rows instead of throwing")
            } catch {
                // The message reaches the user verbatim, so an empty one is a failure
                // in its own right: an error banner with nothing in it is worse than
                // no banner.
                return describe(error).isEmpty ? .failed("threw with an empty message") : .passed
            }
        }
    }

    /// A write says what it did, and does not pretend to be an empty table.
    ///
    /// A SELECT that matched nothing also has no rows, but it has columns, and a grid
    /// with headers and no rows is a truthful account of it. A write has neither, so
    /// without a command summary it renders as a grid of nothing.
    static func commandsReportATag(
        _ session: any Session,
        _ fixture: ConformanceFixture
    ) async -> ConformanceCheck {
        await check("a write reports a command summary") {
            guard session.capabilities.mutation != .readOnly else {
                return .notApplicable("connection is read-only")
            }

            let outcome = try await session.execute(sql: fixture.write)

            guard let command = outcome.command else {
                return .failed("a write returned no command summary")
            }

            guard command.tag != nil else {
                return .failed("the command summary names no statement")
            }

            guard outcome.columns.isEmpty else {
                return .failed("a write reported \(outcome.columns.count) columns")
            }

            return .passed
        }
    }

    /// A connection that says it is read-only refuses a write.
    ///
    /// The check that makes ``EngineCapabilities`` binding rather than advisory. The
    /// grid not drawing an editor stops the usual write; it does not stop a saved
    /// query, a starter snippet or the command palette.
    static func readOnlyRefusesWrites(
        _ session: any Session,
        _ fixture: ConformanceFixture
    ) async -> ConformanceCheck {
        await check("a read-only connection refuses a write") {
            guard session.capabilities.mutation == .readOnly else {
                return .notApplicable("connection permits mutations")
            }

            do {
                _ = try await session.execute(sql: fixture.write)

                return .failed("a read-only connection ran a write")
            } catch {
                return .passed
            }
        }
    }

    /// A connection that takes one statement per request refuses a script rather than
    /// silently running the first statement and dropping the rest.
    static func singleStatementRefusesScripts(
        _ session: any Session,
        _ fixture: ConformanceFixture
    ) async -> ConformanceCheck {
        await check("a single-statement connection refuses a script") {
            guard session.capabilities.scripting == .singleStatement else {
                return .notApplicable("connection accepts scripts")
            }

            do {
                _ = try await session.execute(sql: fixture.script)

                return .failed("a single-statement connection accepted two statements")
            } catch {
                return .passed
            }
        }
    }

    /// Only a metered connection can price a query, and it must not run it.
    static func dryRunMatchesCostModel(
        _ session: any Session,
        _ fixture: ConformanceFixture,
        _ rowCount: Int
    ) async -> ConformanceCheck {
        await check("a dry run is offered exactly where it is meaningful") {
            let request = QueryRequest(.sql(fixture.read(rowCount)), isDryRun: true)

            guard session.capabilities.cost.isMetered else {
                do {
                    _ = try await session.execute(request)

                    return .failed("an unmetered connection accepted a dry run")
                } catch {
                    return .passed
                }
            }

            let outcome = try await session.execute(request)

            guard outcome.rowCount == 0 else {
                return .failed("a dry run returned \(outcome.rowCount) rows")
            }

            guard outcome.statistics.bytesProcessed != nil else {
                return .failed("a dry run reported no estimate")
            }

            return .passed
        }
    }

    /// A cursor runs out, and every store it hands back is longer than the last.
    ///
    /// The growth half is the contract `EditableResult.extend(to:)` depends on: a page
    /// must be a *longer result over the same columns*, not a detached page the caller
    /// has to concatenate.
    static func cursorTerminates(
        _ session: any Session,
        _ fixture: ConformanceFixture,
        _ rowCount: Int
    ) async -> ConformanceCheck {
        await check("a cursor grows monotonically and terminates") {
            guard session.capabilities.pagination == .cursor else {
                return .notApplicable("connection delivers whole results")
            }

            let outcome = try await session.execute(sql: fixture.read(rowCount))

            guard let cursor = outcome.delivery.cursor else {
                return .failed("a paginating connection returned no cursor")
            }

            var delivered = outcome.rowCount
            // Bounded so a cursor that never exhausts fails the check instead of
            // hanging the suite.
            let limit = rowCount + 2

            for _ in 0..<limit {
                guard let store = try await cursor.fetchNext() else {
                    await cursor.close()

                    guard delivered == rowCount else {
                        return .failed("cursor delivered \(delivered) of \(rowCount) rows")
                    }

                    guard await !cursor.mayHaveMore else {
                        return .failed("an exhausted cursor still reports more rows")
                    }

                    return .passed
                }

                guard store.rowCount > delivered else {
                    return .failed("a window went from \(delivered) to \(store.rowCount) rows")
                }

                guard store.columnCount == outcome.columns.count else {
                    return .failed("a window changed the column count")
                }

                delivered = store.rowCount
            }

            return .failed("cursor did not exhaust within \(limit) fetches")
        }
    }

}

// MARK: - Plumbing

private extension EngineConformance {

    /// Runs one check, turning anything thrown into a failure rather than letting it
    /// abandon the rest of the suite. A driver that fails four checks should report
    /// four failures, not the first one.
    ///
    /// Untyped `throws` on purpose. `Session.execute` is typed, but calling it through
    /// `any Session` erases the thrown type, and a suite that has to name `QueryError`
    /// at every call site would not compile against the existential it exists to test.
    static func check(
        _ name: String,
        _ body: () async throws -> ConformanceCheck.Outcome
    ) async -> ConformanceCheck {
        do {
            return ConformanceCheck(name: name, outcome: try await body())
        } catch {
            return ConformanceCheck(name: name, outcome: .failed("threw: \(describe(error))"))
        }
    }

    static func describe(_ error: any Error) -> String {
        (error as? QueryError)?.message ?? String(describing: error)
    }

}

/// Collects partials from the driver's own thread.
///
/// `onPartial` is invoked synchronously on whatever thread is draining rows, so the
/// suite cannot simply append to a local.
private final class PartialRecorder: @unchecked Sendable {

    private struct Snapshot {
        let rowCount: Int
        let columnNames: [String]
    }

    private let lock = NSLock()

    private var snapshots: [Snapshot] = []

    func record(_ partial: PartialResult) {
        let snapshot = Snapshot(rowCount: partial.store.rowCount, columnNames: partial.columns.map(\.name))

        lock.lock()
        defer { lock.unlock() }

        snapshots.append(snapshot)
    }

    var partials: [(rowCount: Int, columnNames: [String])] {
        lock.lock()
        defer { lock.unlock() }

        return snapshots.map { ($0.rowCount, $0.columnNames) }
    }

}
