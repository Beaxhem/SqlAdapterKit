//
//  File.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 05.06.2025.
//

import Foundation
import SqlAdapterKit

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

    public func withConnection<R: Sendable>(_ action: ConnectionAction<R, QueryError>) async throws(QueryError) -> R {
        let connection = try await borrow()

        defer { giveBack(connection) }

        return try await action(connection)
    }

}

extension ConnectionPool where Factory.C: CancellableConnection {

    public func withCancellableConnection<R: Sendable>(_ action: ConnectionAction<R, QueryError>) async throws(QueryError) -> R {
        let connection = try await borrow()
        defer { giveBack(connection) }

        do {
            return try await withTaskCancellationHandler {
                try await action(connection)
            } onCancel: {
                connection.cancelQuery()
            }
        } catch let error as QueryError {
            throw error
        } catch {
            throw .cancelled
        }
    }

}

public extension ConnectionPool {

    func borrow() async throws(QueryError) -> Connection {
        if let pooledConnection = buffer.popLast() {
            return pooledConnection.connection
        }

        return try factory.connect()
    }

    func giveBack(_ connection: Connection) {
        guard buffer.count < maxPoolSize else { return }

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
    func cancelQuery()
}

public protocol ConnectionFactory {
    associatedtype C: Sendable
    func connect() throws(QueryError) -> C
}
