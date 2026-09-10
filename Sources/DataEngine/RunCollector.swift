//
//  RunCollector.swift
//  DataEngine
//

import Foundation
import Synchronization

/// Folds a driver's stream of ``RunEvent``s into a ``RunOutcome``, deciding what is
/// worth keeping as it goes.
///
/// This type exists because "what to keep" is one policy and must be written once. A
/// pasted `mysqldump` is two hundred thousand statements; retaining an outcome for each
/// of them is the difference between a feature and a hang, and a rule enforced in the
/// app but not in the conformance suite is a rule that is only true on Tuesdays.
///
/// Two independent budgets, because they answer different questions:
///
/// - ``detailLimit`` bounds how many statements are described individually. Everything
///   beyond it still lands in ``RunSummary`` — the counts are exact at any size.
/// - ``resultBudget`` bounds how many *results* keep their rows. A script of three
///   hundred `SELECT`s is a different problem from a script of three hundred statements,
///   and capping one does nothing for the other.
///
/// Failures are never dropped by either budget. A run's failures are the whole reason
/// anyone reads it, there is at most one under the default stop-at-first-failure
/// behaviour, and a cap that quietly discarded the only interesting statement would be
/// worse than no cap.
///
/// A `final class` behind a `Mutex` rather than an actor: it is fed from whatever thread
/// the driver reports on, once per statement, and every operation is a handful of
/// arithmetic. An actor would put a suspension in front of each of them and force every
/// driver's report path to become async for no benefit.
public final class RunCollector: Sendable {

    /// How many statements are described individually. Beyond it only failures are
    /// kept; everything else, `SELECT`s included, folds into the counts.
    public let detailLimit: Int

    /// How many statements keep their rows at once.
    ///
    /// Past it a result is kept as the statement it was — tag, counts, statistics —
    /// with its rows released. Which one gives them up is the interesting half: see
    /// ``record(_:)-4x1qk``.
    public let resultBudget: Int

    private let state = Mutex(State())

    public init(detailLimit: Int = 200, resultBudget: Int = 16) {
        self.detailLimit = detailLimit
        self.resultBudget = resultBudget
    }

    private struct State {
        var summary = RunSummary()
        var statements: [StatementOutcome] = []

        /// Where in ``statements`` the outcomes still carrying rows are, oldest first.
        /// Positions rather than ordinals: a statement's index in the script and its
        /// place in this array stop agreeing the moment the detail limit drops one.
        var retained: [Int] = []
    }

}

public extension RunCollector {

    /// Counts so far. Safe to read mid-run — it is what a live strip renders from.
    var summary: RunSummary {
        state.withLock { $0.summary }
    }

    /// Takes one event. Only ``RunEvent/statement(_:)`` is recorded; partials belong to
    /// whoever is drawing the rows and pass straight through.
    func record(_ event: RunEvent) {
        guard case .statement(let outcome) = event else { return }

        record(outcome)
    }

    func record(_ outcome: StatementOutcome) {
        state.withLock { state in
            state.summary.total += 1

            switch outcome.disposition {
            case .succeeded:
                state.summary.succeeded += 1
            case .failed:
                state.summary.failed += 1
                if state.summary.firstFailure == nil {
                    state.summary.firstFailure = outcome.index
                }
            case .skipped:
                state.summary.skipped += 1
            }

            let hasRows = outcome.disposition.hasRows

            if hasRows {
                state.summary.rowReturning += 1
            }

            // A failure is kept whatever the budgets say, and does not count against
            // them: the failures are the whole reason anyone reads a large run.
            guard outcome.disposition.error == nil else {
                state.statements.append(outcome)
                return
            }

            // Everything else is bounded outright. Two hundred thousand writes are
            // fully described by the counts, and so are two hundred thousand `SELECT`s
            // nobody will ever scroll to — the run is already past the point where the
            // strip has become a summary line.
            guard state.statements.count < detailLimit else { return }

            guard hasRows else {
                state.statements.append(outcome)
                return
            }

            // A budget of nothing is not a budget to argue with.
            guard resultBudget > 0 else {
                state.statements.append(
                    StatementOutcome(index: outcome.index, disposition: .released(outcome))
                )
                return
            }

            // The newest result is the one that is kept, and the oldest is the one that
            // pays for it.
            //
            // This used to be the other way round — the first `resultBudget` results
            // stayed and every later one arrived already released — which is wrong for
            // the only two ways anyone reads a run. A script is read from the end: the
            // last `SELECT` is the one it was written to produce, and it is what
            // `ScriptRun.finish` lands the grid on, so keeping the first sixteen of
            // twenty meant the run opened on a statement whose rows it had thrown away.
            // And a run watched as it goes is a tail; the interesting end of a tail is
            // the end it is growing from.
            //
            // The statement itself is never dropped, only its rows: it keeps its place
            // in the order it was reported, and says what it was.
            if state.retained.count == resultBudget, let evicted = state.retained.first {
                let stale = state.statements[evicted]

                state.retained.removeFirst()
                state.statements[evicted] = StatementOutcome(
                    index: stale.index,
                    disposition: .released(stale)
                )
            }

            state.retained.append(state.statements.count)
            state.statements.append(outcome)
        }
    }

    /// Seals the run.
    ///
    /// - Parameter statistics: wall time for the whole run, which only the caller can
    ///   measure — a run that failed has no driver figure to borrow.
    func finish(
        termination: RunOutcome.Termination,
        statistics: ExecutionStatistics
    ) -> RunOutcome {
        state.withLock { state in
            RunOutcome(
                summary: state.summary,
                statements: state.statements,
                termination: termination,
                statistics: statistics
            )
        }
    }

}

private extension StatementDisposition {

    /// The same statement with its rows let go: it still says what it was and how long
    /// it took, and reports no columns, so nothing downstream mistakes it for a query
    /// that returned nothing.
    ///
    /// Deliberately not a case of its own. A released result is a successful statement
    /// whose rows are gone, and every caller that switches on the disposition should go
    /// on treating it as a success — the fact that its rows were dropped belongs on the
    /// screen that would have drawn them, and it reads it off the empty columns.
    static func released(_ outcome: StatementOutcome) -> StatementDisposition {
        guard case .succeeded(let result) = outcome.disposition else { return outcome.disposition }

        return .succeeded(
            ExecutionOutcome(
                columns: [],
                store: .empty,
                command: result.command,
                statistics: result.statistics
            )
        )
    }

}
