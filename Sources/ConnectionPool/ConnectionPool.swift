//
//  File.swift
//  DataEngine
//
//  Created by Illia Senchukov on 05.06.2025.
//

import Foundation
import DataEngine

public actor ConnectionPool<Factory: ConnectionFactory> {

    public typealias Connection = Factory.C
    public typealias ConnectionAction<R, E: Error> = @Sendable (Connection) async throws(E) -> R

    private let factory: Factory

    private var buffer: [PooledConnection<Connection>] = []

    private var cleanupTask: Task<Void, Never>?

    private let maxPoolSize: Int

    public init(factory: Factory) async throws(QueryError) {
        try await self.init(connection: factory.connect(), factory: factory)
    }

    public init(connection: Connection, factory: Factory, maxPoolSize: Int = 3) async {
        self.factory = factory
        self.maxPoolSize = maxPoolSize
        self.buffer = [.init(connection: connection)]
        startCleanupTask()
    }

    deinit {
        cleanupTask?.cancel()
    }

    @concurrent
    public func withConnection<R: Sendable>(_ action: ConnectionAction<R, QueryError>) async throws(QueryError) -> R {
        let connection = try await borrow()

        do {
            let result = try await action(connection)

            await giveBack(connection)

            return result
        } catch {
            // A connection the failure says is broken is dropped rather than buffered.
            // The `defer { Task { await giveBack(connection) } }` this replaces returned
            // every connection unconditionally, which is right for a syntax error and
            // wrong for a dead socket — and wrong in the way that compounds: a pool of
            // three would take three failures to poison completely and then fail every
            // query afterwards, because each borrow handed back one of the corpses.
            if !error.kind.invalidatesSession {
                await giveBack(connection)
            }

            throw error
        }
    }

}

extension ConnectionPool where Factory.C: CancellableConnection {

    public func withCancellableConnection<R: Sendable>(_ action: ConnectionAction<R, QueryError>) async throws(QueryError) -> R {
        let connection = try borrow()

        do {
            let result = try await withTaskCancellationHandler {
                try await action(connection)
            } onCancel: {
                // The detached task keeps a strong reference to `connection`, so
                // the cancel request runs against a still-valid connection even
                // though we deliberately do not return it to the pool below.
                Task {
                    do {
                        try await connection.cancelQuery(pool: self)
                    } catch {
                        print("Failed to cancel query: \(error)")
                    }
                }
            }

            if Task.isCancelled {
                // Cancellation can race with successful completion: `onCancel`
                // may still have dispatched a cancel request against this
                // connection. Drop it so a later query can't be aborted by it.
                throw QueryError.cancelled
            }

            giveBack(connection)
            return result
        } catch {
            if Task.isCancelled {
                // A cancel request may still be in flight against this
                // connection. Dropping it (rather than returning it to the pool)
                // guarantees a later query can't be aborted by this connection's
                // pending cancellation, and reports the outcome uniformly.
                throw QueryError.cancelled
            }

            // A genuine *query* error leaves the connection healthy: return it. A
            // transport failure does not, and the comment that used to stand here said
            // otherwise — it was written when the two were indistinguishable, which they
            // now are not. Returning a connection libpq has already marked bad means the
            // next borrower inherits it and fails for a reason that has nothing to do
            // with what they asked.
            let failure = (error as? QueryError) ?? .cancelled

            if !failure.kind.invalidatesSession {
                giveBack(connection)
            }

            throw failure
        }
    }

}

public extension ConnectionPool {

    /// Drops every buffered connection, on the assumption that all of them are dead.
    ///
    /// What the app calls when it learns something the pool cannot: the machine woke, or
    /// the network path changed underneath it. Both leave every open socket unusable
    /// while the client library still believes otherwise, because nothing has tried to
    /// use one yet — so ``borrow()``'s check would pass and hand out a corpse.
    ///
    /// Nothing is reopened here. The next borrow connects, which means the cost of being
    /// wrong about this is one handshake and never a failed query.
    func invalidate() {
        buffer.removeAll()
    }

    /// A connection from the buffer, or a new one.
    ///
    /// Buffered connections are checked before they are handed out, and the check is
    /// deliberately a local one — see the factory's ``ConnectionFactory/isAlive(_:)``. It
    /// costs a pointer dereference and catches the case that matters most in a desktop
    /// app: the machine slept, or the route out changed when a VPN came up, and every
    /// socket the pool is holding is dead. Without it the user sees one failure per
    /// buffered connection before the pool is finally empty enough to open a live one.
    func borrow() throws(QueryError) -> Connection {
        while let pooledConnection = buffer.popLast() {
            if factory.isAlive(pooledConnection.connection) {
                return pooledConnection.connection
            }
        }

        return try factory.connect()
    }

    func giveBack(_ connection: Connection) {
        guard buffer.count < maxPoolSize else {
            return
        }

        buffer.append(.init(connection: connection))
    }

}

private extension ConnectionPool {

    func startCleanupTask() {
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))

                await self?.cleanup()
            }
        }
    }

    func cleanup() {
        guard buffer.count > 1 else { return }

        var remove = 0

        for connection in buffer {
            guard connection.lifetime > 30 else { break }

            remove += 1
        }

        remove = min(remove, buffer.count - 1)
        buffer.removeFirst(remove)
    }

}

private extension ConnectionPool {

    struct PooledConnection<Connection> {
        let connection: Connection
        let lastUsed = Date()

        var lifetime: TimeInterval {
            Date().timeIntervalSince(lastUsed)
        }
    }

}

public protocol CancellableConnection: Sendable {
    func cancelQuery<Factory, Pool: ConnectionPool<Factory>>(pool: Pool) async throws(QueryError) where Factory.C == Self
}

/// `Sendable`, because the pool is an actor that holds the factory and calls it from
/// its own executor. Without it the conformance could be actor-isolated, which makes
/// every hop into the pool — `borrow`, `giveBack`, the cleanup task — a conformance the
/// compiler cannot prove is safe to use there, and `Factory.Type` a metatype it will not
/// let a closure capture.
public protocol ConnectionFactory: Sendable {
    associatedtype C: Sendable
    func connect() throws(QueryError) -> C

    /// Whether `connection` is still usable, answered **without a round trip**.
    ///
    /// Called on every borrow, so anything that talks to the server here is a full
    /// network round trip added to the front of every query the pool serves — which on a
    /// managed cluster is more latency than most of the queries themselves. What belongs
    /// here is the client library's own opinion: `PQstatus`, or MySQL's last error code.
    ///
    /// The default answers yes, which keeps a driver that has not implemented it behaving
    /// exactly as it did. It is not a safe default so much as a neutral one: a connection
    /// wrongly called alive fails on its first statement and is then dropped by the
    /// failure classification instead, which is one visible error rather than none.
    func isAlive(_ connection: C) -> Bool
}

public extension ConnectionFactory {

    func isAlive(_ connection: C) -> Bool { true }

}
