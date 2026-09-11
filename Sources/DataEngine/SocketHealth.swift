//
//  SocketHealth.swift
//  DataEngine
//

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Whether a socket a pool is holding still looks like a live, idle connection.
///
/// This exists because the client libraries cannot answer the question that matters.
/// `PQstatus` and `mysql_errno` report what the library has *already discovered*, which
/// means they only ever go bad after something has failed — and the case a pool needs to
/// catch is the one where nothing has been tried yet: the machine slept for an hour, or a
/// VPN came up and changed the route out, and every socket in the buffer is dead while
/// the library still cheerfully reports OK.
///
/// The trick is that an idle database connection is *silent*. Neither Postgres nor MySQL
/// sends anything unbidden on a connection with no statement in flight, so a socket that
/// has become readable while parked in a pool has not received a row — it has received a
/// FIN, or an RST, or the kernel has marked it hung up. Asking the kernel that costs a
/// non-blocking `poll` with a zero timeout: no round trip, no syscall to the server, and
/// an answer accurate for every way a connection dies short of a black hole.
///
/// What it cannot see is the black hole — a route that silently stops delivering, which
/// is what a VPN dropping without tearing down looks like. Nothing local can see that
/// one; keepalives are what eventually turn it into a closed socket that this then
/// detects. See ``ConnectionResilience/Keepalive``.
public enum SocketHealth {

    /// Whether `descriptor` is an idle socket with nothing pending on it.
    ///
    /// - Returns: false when the socket is readable, hung up, in error, or not a socket
    ///   at all. True when the kernel has nothing to report, **and** when `poll` itself
    ///   fails — an unanswerable question is not evidence of a dead connection, and
    ///   throwing away a working connection because a syscall misbehaved would trade a
    ///   rare failure for a reliable one.
    public static func isQuiet(_ descriptor: Int32) -> Bool {
        guard descriptor >= 0 else { return false }

        // `POLLHUP`, `POLLERR` and `POLLNVAL` are reported whether or not they were
        // asked for, so requesting readability alone covers every case.
        var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)

        let ready = withUnsafeMutablePointer(to: &descriptors) { poll($0, 1, 0) }

        // Below zero is `poll` failing rather than the socket failing; zero is the
        // healthy answer — nothing to read, nothing hung up, nothing in error.
        return ready <= 0
    }

}
