//
//  File.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 05.06.2025.
//

import Foundation
import SqlAdapterKit

public actor ConnectionPool<Factory: ConnectionFactory> {

    public typealias Connection = Factory.Connection
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
        let connection = try await self.borrow()
        defer { giveBack(connection) }

        return try await action(connection)
    }

}

private extension ConnectionPool {

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
        cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))

                cleanup()
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

public protocol ConnectionFactory {
    associatedtype Connection: Sendable
    func connect() throws(QueryError) -> Connection
}
