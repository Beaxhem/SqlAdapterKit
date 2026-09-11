//
//  FaultProxy.swift
//  DataEngineTestKit
//

import Foundation
import Network

/// A TCP proxy that can break on demand, so the ways a network fails become things a
/// test can cause.
///
/// Everything this package does about dropped connections is untestable without it.
/// A driver's recovery path is reached only by a socket that dies at a particular
/// moment — while idle, mid-result, during the handshake — and none of those can be
/// arranged against a real server: stopping the server is a different event, and one
/// that takes seconds and affects every other test running at the time.
///
/// So the driver is pointed at this instead of at the database, and it forwards
/// faithfully until it is told not to. Each ``Fault`` is a distinct real-world failure,
/// and they are distinct because drivers behave differently across them — a reset is
/// noticed immediately and a black hole is not noticed at all until a keepalive or a
/// timeout expires, which is exactly the difference the resilience settings exist to
/// manage.
///
/// Test-only, and it lives in the test kit rather than in a test file because all six
/// driver packages need the same thing.
public final class FaultProxy: @unchecked Sendable {

    /// What the proxy is doing to traffic right now.
    public enum Fault: Sendable, Equatable {

        /// Forward both directions faithfully. A working network.
        case forward

        /// Accept connections, forward nothing, and never close.
        ///
        /// **The VPN case**, and the reason it is separate from ``reset``. When a VPN
        /// interface goes away the packets stop arriving and nothing tells either end;
        /// both sides believe the connection is fine, and the client discovers otherwise
        /// only when something times out. Nothing local can detect this state — which is
        /// what makes it the case worth having a test for.
        case blackhole

        /// Close every connection, at once and on arrival.
        ///
        /// A server that restarted, or a firewall that started sending RSTs. Noticed
        /// immediately by both `PQstatus` and a socket poll.
        case reset

        /// Accept the TCP connection and then never speak.
        ///
        /// A handshake that hangs: what a half-open route or an overloaded server looks
        /// like. This is what `connect_timeout` exists for, and without it the attempt
        /// waits out the operating system's patience rather than the app's.
        case stallHandshake

    }

    private let upstreamHost: String

    private let upstreamPort: UInt16

    private let listener: NWListener

    private let queue = DispatchQueue(label: "FaultProxy")

    private let lock = NSLock()

    private var _fault: Fault = .forward

    private var live: [NWConnection] = []

    /// The port to point a driver at. Ephemeral, so parallel tests do not collide.
    public private(set) var port: UInt16 = 0

    /// What the proxy is currently doing. Settable at any time, including mid-query.
    public var fault: Fault {
        get { lock.withLock { _fault } }
        set { lock.withLock { _fault = newValue } }
    }

    /// Starts listening, and returns once the port is known.
    public init(forwardingTo host: String, port upstreamPort: UInt16) throws {
        self.upstreamHost = host
        self.upstreamPort = upstreamPort

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        self.listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self, let assigned = self.listener.port else { return }

            self.port = assigned.rawValue
            ready.signal()
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()

            throw ProxyError.didNotStart
        }
    }

    deinit {
        stop()
    }

}

public extension FaultProxy {

    enum ProxyError: Error {
        case didNotStart
    }

    /// Kills every connection currently open through the proxy, leaving the listener up.
    ///
    /// The distinction from setting ``Fault/reset`` matters: this breaks the connections
    /// that already exist while letting new ones succeed, which is what a server restart
    /// looks like from a pool holding three idle sockets. Setting the fault instead
    /// breaks the reconnect as well.
    func cutLiveConnections() {
        let connections = lock.withLock {
            let open = live
            live = []

            return open
        }

        for connection in connections {
            connection.forceCancel()
        }
    }

    /// How many connections are currently open through the proxy.
    ///
    /// What a pool test asserts on: that a borrow after a cut opened a new socket rather
    /// than handing back a dead one.
    var openConnectionCount: Int {
        lock.withLock { live.count }
    }

    func stop() {
        cutLiveConnections()
        listener.cancel()
    }

}

private extension FaultProxy {

    func accept(_ inbound: NWConnection) {
        switch fault {
        case .reset:
            inbound.forceCancel()

            return

        case .stallHandshake, .blackhole:
            // Accepted and then ignored: no upstream connection is made at all, so the
            // client sits in a completed TCP connection that will never answer.
            inbound.start(queue: queue)

            track(inbound)

            return

        case .forward:
            break
        }

        let outbound = NWConnection(
            host: .init(upstreamHost),
            port: .init(rawValue: upstreamPort) ?? .any,
            using: .tcp
        )

        track(inbound)
        track(outbound)

        inbound.start(queue: queue)
        outbound.start(queue: queue)

        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
    }

    func track(_ connection: NWConnection) {
        lock.withLock { live.append(connection) }
    }

    /// Copies one direction until it ends, checking the fault on every chunk.
    ///
    /// Checked per chunk rather than once at accept time so a fault can be introduced
    /// *mid-query* — which is the interesting moment, and the one that distinguishes a
    /// driver that notices a short result from one that hands the caller a truncated
    /// answer and calls it complete.
    func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            switch self.fault {
            case .reset:
                source.forceCancel()
                destination.forceCancel()

                return

            case .blackhole:
                // Read and dropped. Neither end is told, and neither end can tell —
                // which is the whole point of this case.
                self.pump(from: source, to: destination)

                return

            case .forward, .stallHandshake:
                break
            }

            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }

            if isComplete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)

                return
            }

            self.pump(from: source, to: destination)
        }
    }

}
