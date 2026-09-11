//
//  ConnectionResilience.swift
//  DataEngine
//

import Foundation

/// How long a connection waits, and how it proves it is still there.
///
/// One type for every driver that opens a socket, because the settings are the same
/// three questions everywhere and only the spelling differs — libpq takes them as URI
/// parameters, MySQL as `mysql_options` calls, `URLSession` as properties on a
/// configuration. What varies is which of them an engine can express; each driver
/// applies what it can and ignores the rest.
///
/// The defaults exist because the *library* defaults are wrong for a desktop app on a
/// laptop. Every client here defaults to "wait as long as the operating system is
/// willing to", which was written for a server process on a wired network and is the
/// direct cause of the two worst behaviours a user sees: a connection attempt that
/// hangs for a minute after the VPN drops, and a connection that appears fine for hours
/// after the network underneath it went away.
public struct ConnectionResilience: Sendable, Hashable {

    /// TCP keepalive, which is how an idle connection finds out it is dead.
    ///
    /// Worth stating what this is *for*, because it is not what it sounds like. It does
    /// not keep anything alive on the server — Postgres and MySQL both have their own,
    /// much longer, idle timeouts and neither cares about these packets. What it does is
    /// keep the *path* alive, and discover promptly when the path has gone: a NAT or a
    /// VPN concentrator drops an idle mapping after a few minutes and tells nobody, so
    /// without keepalives the next query goes into a hole and waits out the full TCP
    /// retransmission schedule — on the order of fifteen minutes — before failing.
    ///
    /// With the defaults below the same connection reports itself broken about a minute
    /// after it actually broke, and reports it as a connection failure rather than as a
    /// query that never returned.
    public struct Keepalive: Sendable, Hashable {

        /// Idle seconds before the first probe.
        public let idle: TimeInterval

        /// Seconds between probes once they start.
        public let interval: TimeInterval

        /// Unanswered probes before the connection is declared dead.
        public let count: Int

        /// Seconds of unacknowledged retransmission before the connection is dropped, or
        /// nil to leave the system's schedule alone.
        ///
        /// The other half of the same job, and the half that keepalive probes do not do.
        /// Keepalives only run on a connection with **nothing outstanding**; the moment
        /// there is unacknowledged data — a query on its way to a server that can no
        /// longer be reached — TCP switches to retransmitting instead, and left alone it
        /// works through the full schedule, on the order of fifteen minutes.
        ///
        /// So the two cover the two states a stranded connection can be in: idle, and
        /// waiting for an answer. A client that sets only keepalives has bounded the case
        /// where nothing was happening and left unbounded the case where the user was
        /// waiting for a result.
        public let retransmitDropTime: TimeInterval?

        public init(
            idle: TimeInterval = 30,
            interval: TimeInterval = 10,
            count: Int = 3,
            retransmitDropTime: TimeInterval? = 20
        ) {
            self.idle = idle
            self.interval = interval
            self.count = count
            self.retransmitDropTime = retransmitDropTime
        }

    }

    /// Seconds to wait for a connection to be established.
    ///
    /// Ten, which is chosen against the two failure modes rather than as a round number:
    /// long enough for a TLS handshake to a managed cluster on another continent over a
    /// slow link, short enough that a route which no longer goes anywhere fails while
    /// the user is still looking at the screen. Left unset, the wait is the operating
    /// system's TCP connect timeout — around 75 seconds — and on a blocking driver it is
    /// 75 seconds of a thread that Swift cancellation cannot reclaim.
    public let connectTimeout: TimeInterval

    /// Seconds to wait for a reply once connected, or nil to wait indefinitely.
    ///
    /// **Nil by default, and it must stay nil.** This is not a query timeout in disguise:
    /// the drivers that offer it apply it per network read, so a legitimately slow query
    /// — a warehouse scan, a report over a year of data — is indistinguishable from a
    /// dead socket and gets killed on the same clock. Keepalives answer the same question
    /// without that cost, which is why they are on by default and this is not.
    public let readTimeout: TimeInterval?

    /// Seconds to wait for a write to be accepted, or nil to wait indefinitely.
    public let writeTimeout: TimeInterval?

    /// Keepalive settings, or nil to leave the connection unprobed.
    public let keepalive: Keepalive?

    public init(
        connectTimeout: TimeInterval = 10,
        readTimeout: TimeInterval? = nil,
        writeTimeout: TimeInterval? = nil,
        keepalive: Keepalive? = Keepalive()
    ) {
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
        self.keepalive = keepalive
    }

    /// What every connection gets unless something says otherwise.
    public static let `default` = ConnectionResilience()

    /// No timeouts, no probes — the library defaults, restored.
    ///
    /// For the tests that need to observe a hang rather than have it cut short, and for
    /// a local socket where none of this buys anything.
    public static let none = ConnectionResilience(
        connectTimeout: 0,
        readTimeout: nil,
        writeTimeout: nil,
        keepalive: nil
    )

}
