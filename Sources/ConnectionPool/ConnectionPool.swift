//
//  File.swift
//  SqlAdapterKit
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

        defer {
            Task {
                await giveBack(connection)
            }
        }

        return try await action(connection)
    }

}

extension ConnectionPool where Factory.C: CancellableConnection {

    public func withCancellableConnection<R: Sendable>(_ action: ConnectionAction<R, QueryError>) async throws(QueryError) -> R {
        let connection = try borrow()

        do {
            let result = try await withTaskCancellationHandler {
                try await action(connection)
            } onCancel: {
                print("Cancel query")

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

            // A genuine query error leaves the connection healthy: return it.
            giveBack(connection)

            if let error = error as? QueryError {
                throw error
            }
            throw QueryError.cancelled
        }
    }

}

public extension ConnectionPool {

    func borrow() throws(QueryError) -> Connection {
        if let pooledConnection = buffer.popLast() {
            return pooledConnection.connection
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

public protocol ConnectionFactory {
    associatedtype C: Sendable
    func connect() throws(QueryError) -> C
}
