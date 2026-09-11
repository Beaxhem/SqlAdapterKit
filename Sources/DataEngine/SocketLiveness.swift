//
//  SocketLiveness.swift
//  DataEngine
//

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Asks the kernel to give up on a connection that has stopped answering.
///
/// The companion to ``SocketHealth``, and the division between them is worth stating:
/// that one *observes* a socket the kernel has already given up on, this one is what
/// makes the kernel give up in the first place. Neither is much use without the other —
/// polling a socket the kernel will nurse for fifteen minutes reports a healthy
/// connection for fifteen minutes.
///
/// Applied directly to the file descriptor rather than through each client library,
/// because the libraries disagree about what they expose. libpq takes keepalives as
/// connection-string parameters and offers nothing for the retransmission schedule;
/// MySQL's client offers neither. Both hand out the descriptor — `PQsocket`, and
/// `MYSQL.net.fd` — so the one place this can be said uniformly is here.
public enum SocketLiveness {

    /// Applies `keepalive` to `descriptor`.
    ///
    /// Best effort by design. A kernel that refuses one of these leaves a working
    /// connection that is merely slower to notice a black hole, and there is nothing
    /// useful to tell a user about that — so nothing here reports failure. What *is*
    /// worth guarding against is a silently ignored option, which is what a wrong level
    /// or a wrong constant looks like; that is what ``settings(of:)`` exists for.
    public static func apply(_ keepalive: ConnectionResilience.Keepalive?, to descriptor: Int32) {
        guard descriptor >= 0, let keepalive else { return }

        func set(_ level: Int32, _ option: Int32, _ value: Int32) {
            var value = value

            setsockopt(fd: descriptor, level, option, &value)
        }

        set(SOL_SOCKET, SO_KEEPALIVE, 1)
        set(IPPROTO_TCP, TCP_KEEPALIVE, Int32(keepalive.idle))
        set(IPPROTO_TCP, TCP_KEEPINTVL, Int32(keepalive.interval))
        set(IPPROTO_TCP, TCP_KEEPCNT, Int32(keepalive.count))

        if let dropTime = keepalive.retransmitDropTime {
            set(IPPROTO_TCP, TCP_RXT_CONNDROPTIME, Int32(dropTime))
        }
    }

    private static func setsockopt(
        fd: Int32,
        _ level: Int32,
        _ option: Int32,
        _ value: UnsafeMutablePointer<Int32>
    ) {
        _ = Darwin.setsockopt(fd, level, option, value, socklen_t(MemoryLayout<Int32>.size))
    }

}

public extension SocketLiveness {

    /// What the kernel says is actually set on `descriptor`.
    ///
    /// Only for tests, and it earns its place there. Every call in ``apply(_:to:)``
    /// discards its result, which is right for production and means a mistake in a level
    /// or an option constant is completely silent — the connection keeps working and
    /// simply never gains the behaviour. Reading the values back is the only way to tell
    /// "applied" from "ignored", and it is the failure this whole feature is most likely
    /// to have.
    struct Settings: Equatable, Sendable {

        public var isKeepaliveEnabled: Bool

        public var idle: Int32

        public var interval: Int32

        public var count: Int32

        public var retransmitDropTime: Int32

    }

    static func settings(of descriptor: Int32) -> Settings {
        func get(_ level: Int32, _ option: Int32) -> Int32 {
            var value: Int32 = -1
            var size = socklen_t(MemoryLayout<Int32>.size)

            guard getsockopt(descriptor, level, option, &value, &size) == 0 else { return -1 }

            return value
        }

        return Settings(
            isKeepaliveEnabled: get(SOL_SOCKET, SO_KEEPALIVE) != 0,
            idle: get(IPPROTO_TCP, TCP_KEEPALIVE),
            interval: get(IPPROTO_TCP, TCP_KEEPINTVL),
            count: get(IPPROTO_TCP, TCP_KEEPCNT),
            retransmitDropTime: get(IPPROTO_TCP, TCP_RXT_CONNDROPTIME)
        )
    }

}
