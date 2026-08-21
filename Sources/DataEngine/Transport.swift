//
//  Transport.swift
//  DataEngine
//

import Foundation
import Dispatch

/// How a driver actually reaches its database.
///
/// This is the whole of the sync/async distinction, and it is deliberately *not* a
/// second ``Session`` protocol. Every caller in the app is already async, so a driver
/// that blocks and a driver that suspends look identical from above; what differs is
/// where their work may run and whether holding a connection open means anything.
/// Stating that once, here, is what lets one protocol serve both.
///
/// - `.blocking` — a C library that occupies its thread for the duration of a call:
///   libpq, sqlite3, libduckdb. Its session is placed on a ``BlockingExecutor`` so
///   the call never occupies a cooperative-pool thread, and connections are worth
///   pooling because opening one costs a handshake.
/// - `.concurrent` — an `URLSession`-shaped driver that suspends rather than blocks.
///   There is no thread to protect and no connection to reuse, so it gets neither.
public enum ExecutionModel: Sendable, Equatable {

    /// - Parameter poolSize: connections kept alive between statements. One means a
    ///   session is strictly serial, which is the right answer for a file-backed
    ///   engine — SQLite and DuckDB open the same file, not a second server.
    case blocking(poolSize: Int)

    case concurrent

    public var isBlocking: Bool {
        if case .blocking = self { true } else { false }
    }

    /// How many statements a session of this kind can have in flight. Blocking
    /// sessions are bounded by their pool; an async one is bounded by the server.
    public var maximumConcurrentStatements: Int {
        switch self {
        case .blocking(let poolSize): max(1, poolSize)
        case .concurrent: .max
        }
    }

}

/// A serial executor backed by one dedicated dispatch queue.
///
/// Installed as an actor's `unownedExecutor` so that everything the actor does happens
/// on a thread the cooperative pool does not own. That is the point, and it is a real
/// change from what the drivers do today: `@concurrent` moves work off the *caller*,
/// but it moves it onto the global concurrent executor — which is the cooperative
/// pool. A blocking `PQexec` there occupies one of a small, fixed number of threads
/// for the length of the query, and enough concurrent statements will starve every
/// other async task in the process, including the ones drawing the window.
///
/// A dispatch queue was the only mechanism available when this was written, at a macOS 14
/// deployment target. `TaskExecutor` (SE-0417) expresses the same intent more directly and
/// needs macOS 15, which the app now targets — so this is a deliberate *not yet*, not a
/// constraint. Custom serial executors (SE-0392) work here and an actor is serial anyway,
/// so nothing is given up by leaving it; the migration is worth doing on its own, against
/// the drivers that depend on it, rather than folded into an unrelated change.
public final class BlockingExecutor: SerialExecutor {

    private let queue: DispatchQueue

    /// - Parameter label: shows up in a crash report and in Instruments, so it should
    ///   name the connection rather than the type — `postgres://…/orders`, not
    ///   `BlockingExecutor`.
    public init(label: String, qos: DispatchQoS = .userInitiated) {
        self.queue = DispatchQueue(label: label, qos: qos, autoreleaseFrequency: .workItem)
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        // `UnownedJob` because the job has to outlive this scope to be run on the
        // queue, and `ExecutorJob` is non-copyable and cannot be captured.
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()

        queue.async { job.runSynchronously(on: executor) }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Lets the runtime verify an isolation claim rather than take it on trust, which
    /// is what turns a mis-annotated `nonisolated(unsafe)` into a crash at the point
    /// of the mistake instead of data corruption somewhere downstream.
    public func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

}
