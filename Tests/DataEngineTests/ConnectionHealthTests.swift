//
//  ConnectionHealthTests.swift
//  DataEngineTests
//

import Testing
import Foundation
import DataEngine
import ConnectionPool

/// A connection that can be killed, and a factory that counts how often it is asked for
/// a new one.
///
/// The pool's whole job in a failure is deciding whether to keep what it has, so every
/// assertion here is about `connectCount`: a pool that recovers correctly opens exactly
/// one new connection, and a pool that does not either opens none — handing back a
/// corpse — or opens one per borrow.
private final class FakeConnection: @unchecked Sendable {

    let serial: Int

    private let lock = NSLock()

    private var _isAlive = true

    var isAlive: Bool {
        get { lock.withLock { _isAlive } }
        set { lock.withLock { _isAlive = newValue } }
    }

    init(serial: Int) {
        self.serial = serial
    }

}

private struct FakeFactory: ConnectionFactory {

    final class Ledger: @unchecked Sendable {

        private let lock = NSLock()

        private var _issued: [FakeConnection] = []

        var connectCount: Int { lock.withLock { _issued.count } }

        var issued: [FakeConnection] { lock.withLock { _issued } }

        func record(_ connection: FakeConnection) {
            lock.withLock { _issued.append(connection) }
        }

    }

    let ledger: Ledger

    func connect() throws(QueryError) -> FakeConnection {
        let connection = FakeConnection(serial: ledger.connectCount)

        ledger.record(connection)

        return connection
    }

    func isAlive(_ connection: FakeConnection) -> Bool {
        connection.isAlive
    }

}

@Suite("Failure classification")
struct FailureKindTests {

    /// The distinction the whole recovery path rests on. A statement failure must leave
    /// the connection alone, or every typo costs a reconnect.
    @Test("only transport and authentication put the session in question")
    func invalidation() {
        #expect(FailureKind.transport.invalidatesSession)
        #expect(FailureKind.authentication.invalidatesSession)

        #expect(!FailureKind.statement.invalidatesSession)
        #expect(!FailureKind.timeout.invalidatesSession)
        #expect(!FailureKind.cancelled.invalidatesSession)
        #expect(!FailureKind.unsupported.invalidatesSession)
    }

    /// Authentication is the one that has to be excluded by name. Reconnecting on a
    /// rejected password is how an account gets locked out rather than recovered — see
    /// ``FailureKind/authentication``.
    @Test("only transport may be reconnected without asking")
    func automaticReconnect() {
        #expect(FailureKind.transport.permitsAutomaticReconnect)

        for kind: FailureKind in [.statement, .authentication, .timeout, .cancelled, .unsupported] {
            #expect(!kind.permitsAutomaticReconnect, "\(kind) should not reconnect on its own")
        }
    }

    /// An unclassified error is a statement error, which is the conservative reading: a
    /// driver that has not been taught to recognise its transport failures reports them
    /// as something the app will never act on by itself.
    @Test("an unclassified error is a statement error")
    func defaultKind() {
        #expect(QueryError(message: "syntax error").kind == .statement)
    }

    /// `QueryRunner` compares against `.cancelled` by equality, so the static has to keep
    /// matching what the drivers throw.
    @Test("the cancelled and disconnected statics carry their kinds")
    func statics() {
        #expect(QueryError.cancelled.kind == .cancelled)
        #expect(QueryError.disconnected.kind == .transport)
    }

    @Test("relabelling keeps the message")
    func relabelling() {
        let original = QueryError(message: "server closed the connection unexpectedly")

        #expect(original.classified(as: .transport).kind == .transport)
        #expect(original.classified(as: .transport).message == original.message)
    }

}

@Suite("Connection pool health")
struct ConnectionPoolHealthTests {

    /// The headline bug this replaces. A transport failure used to return the connection
    /// to the buffer under the comment "a genuine query error leaves the connection
    /// healthy" — true of a syntax error, false of a dead socket — so the pool refilled
    /// itself with corpses and every later query failed.
    @Test("a transport failure drops the connection instead of buffering it")
    func transportFailureDropsTheConnection() async throws {
        let ledger = FakeFactory.Ledger()
        let factory = FakeFactory(ledger: ledger)
        let pool = await ConnectionPool(connection: try factory.connect(), factory: factory)

        await #expect(throws: QueryError.self) {
            try await pool.withConnection { (connection: FakeConnection) throws(QueryError) in
                connection.isAlive = false

                throw QueryError(message: "server closed the connection", kind: .transport)
            }
        }

        // The next borrow must not be able to find the failed connection.
        let serial = try await pool.withConnection { (connection: FakeConnection) throws(QueryError) in
            connection.serial
        }

        #expect(serial == 1, "the borrow reused the connection the failure invalidated")
        #expect(ledger.connectCount == 2)
    }

    /// The other half of the same rule, and the one that keeps the change cheap: a
    /// statement failure is not a reason to throw away a working connection.
    @Test("a statement failure returns the connection")
    func statementFailureKeepsTheConnection() async throws {
        let ledger = FakeFactory.Ledger()
        let factory = FakeFactory(ledger: ledger)
        let pool = await ConnectionPool(connection: try factory.connect(), factory: factory)

        await #expect(throws: QueryError.self) {
            try await pool.withConnection { (_: FakeConnection) throws(QueryError) in
                throw QueryError(message: "column \"nope\" does not exist")
            }
        }

        let serial = try await pool.withConnection { (connection: FakeConnection) throws(QueryError) in
            connection.serial
        }

        #expect(serial == 0, "a syntax error cost the pool its connection")
        #expect(ledger.connectCount == 1)
    }

    /// The wake-from-sleep case. Nothing failed — nothing was *tried* — and every socket
    /// in the buffer is dead. Without the check on borrow the user sees one failure per
    /// buffered connection before the pool is empty enough to open a live one.
    @Test("a borrow skips connections that died while idle")
    func borrowSkipsDeadConnections() async throws {
        let ledger = FakeFactory.Ledger()
        let factory = FakeFactory(ledger: ledger)
        let pool = await ConnectionPool(connection: try factory.connect(), factory: factory)

        // Fill the buffer, then kill everything in it the way a sleep would.
        await pool.giveBack(try factory.connect())
        await pool.giveBack(try factory.connect())

        for connection in ledger.issued {
            connection.isAlive = false
        }

        let borrowed = try await pool.borrow()

        #expect(borrowed.isAlive, "the pool handed out a connection that had died while idle")
        #expect(ledger.connectCount == 4, "it should have opened exactly one replacement")
    }

    /// What the app calls on wake, or when the network path changes. The pool cannot
    /// discover this on its own — `isAlive` would still say yes, because nothing has been
    /// tried since — so it has to be told.
    @Test("invalidate empties the buffer without reopening anything")
    func invalidateEmptiesTheBuffer() async throws {
        let ledger = FakeFactory.Ledger()
        let factory = FakeFactory(ledger: ledger)
        let pool = await ConnectionPool(connection: try factory.connect(), factory: factory)

        await pool.giveBack(try factory.connect())

        await pool.invalidate()

        #expect(ledger.connectCount == 2, "invalidating should not open anything")

        _ = try await pool.borrow()

        #expect(ledger.connectCount == 3, "the borrow after invalidation should have opened a connection")
    }

}

@Suite("Socket health")
struct SocketHealthTests {

    /// A pipe stands in for a socket: the read end has nothing pending, which is what an
    /// idle database connection looks like.
    @Test("an idle descriptor is quiet")
    func idleIsQuiet() throws {
        var descriptors: [Int32] = [0, 0]

        #expect(pipe(&descriptors) == 0)

        defer {
            close(descriptors[0])
            close(descriptors[1])
        }

        #expect(SocketHealth.isQuiet(descriptors[0]))
    }

    /// The case the check exists for. The far end going away makes the descriptor
    /// readable — at end-of-file — and an idle database connection never is.
    @Test("a descriptor whose peer has gone is not quiet")
    func closedPeerIsNotQuiet() throws {
        var descriptors: [Int32] = [0, 0]

        #expect(pipe(&descriptors) == 0)

        defer { close(descriptors[0]) }

        close(descriptors[1])

        #expect(!SocketHealth.isQuiet(descriptors[0]))
    }

    @Test("data waiting means the connection is not idle")
    func pendingDataIsNotQuiet() throws {
        var descriptors: [Int32] = [0, 0]

        #expect(pipe(&descriptors) == 0)

        defer {
            close(descriptors[0])
            close(descriptors[1])
        }

        var byte: UInt8 = 1

        #expect(write(descriptors[1], &byte, 1) == 1)
        #expect(!SocketHealth.isQuiet(descriptors[0]))
    }

    @Test("a closed descriptor is not quiet")
    func closedDescriptor() {
        #expect(!SocketHealth.isQuiet(-1))
    }

}

@Suite("Socket liveness")
struct SocketLivenessTests {

    /// Makes a real TCP socket. The options below are per-protocol, so a `socketpair` or
    /// a pipe would accept the calls and answer nothing useful.
    private func tcpSocket() throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)

        try #require(descriptor >= 0)

        return descriptor
    }

    /// The one failure this whole feature is most likely to have, and the only one that
    /// is completely invisible: `setsockopt` with a wrong level or a wrong option is not
    /// an error anywhere. The connection goes on working and simply never gains the
    /// behaviour — so the bug looks exactly like a network that is slow to fail, which is
    /// the thing being fixed.
    ///
    /// `apply` discards every result, deliberately. Reading them back is the only way to
    /// tell "applied" from "ignored".
    @Test("the options actually reach the socket")
    func optionsAreApplied() throws {
        let descriptor = try tcpSocket()

        defer { close(descriptor) }

        SocketLiveness.apply(
            .init(idle: 12, interval: 4, count: 2, retransmitDropTime: 18),
            to: descriptor
        )

        let settings = SocketLiveness.settings(of: descriptor)

        #expect(settings.isKeepaliveEnabled)
        #expect(settings.idle == 12)
        #expect(settings.interval == 4)
        #expect(settings.count == 2)
        #expect(settings.retransmitDropTime == 18)
    }

    /// Nil means "leave the system's own schedule alone", which has to mean *untouched* —
    /// writing zeroes would be a different and much worse thing to do.
    @Test("no keepalive leaves the socket alone")
    func nilLeavesTheSocketAlone() throws {
        let descriptor = try tcpSocket()

        defer { close(descriptor) }

        let before = SocketLiveness.settings(of: descriptor)

        SocketLiveness.apply(nil, to: descriptor)

        #expect(SocketLiveness.settings(of: descriptor) == before)
        #expect(!SocketLiveness.settings(of: descriptor).isKeepaliveEnabled)
    }

    /// A closed or invalid descriptor is a no-op, not a crash — `PQsocket` returns -1 for
    /// a connection that has no socket.
    @Test("an invalid descriptor is refused quietly")
    func invalidDescriptor() {
        SocketLiveness.apply(.init(), to: -1)
    }

    /// The shipped defaults bound both states a stranded connection can be in. A
    /// `retransmitDropTime` of nil would leave a query outstanding on a dead link for the
    /// full retransmission schedule — about fifteen minutes.
    @Test("the default keepalive bounds the outstanding-query case too")
    func defaultsBoundRetransmission() {
        let keepalive = try! #require(ConnectionResilience.default.keepalive)

        #expect(keepalive.retransmitDropTime != nil, "a query on a dead link would hang")
        #expect((keepalive.retransmitDropTime ?? 0) <= 60)
    }

}
