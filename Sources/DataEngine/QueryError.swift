//
//  QueryError.swift
//  DataEngine
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

/// What kind of failure this was — which is to say, what can be done about it.
///
/// The distinction the app could not make before this existed. A ``QueryError`` was a
/// message, so every consumer of one had the same two options: show it, or don't. That
/// is fine for a syntax error and wrong for a dropped socket, because the two need
/// opposite handling and are indistinguishable as strings — "server closed the
/// connection unexpectedly" and "column does not exist" are both just text.
///
/// The cases are drawn along the line of *what recovers them*, not along the line of
/// where they came from. Two failures that need the same response are one case however
/// differently they read in a log.
public enum FailureKind: Sendable, Hashable, Codable {

    /// The server received the statement, understood it, and refused it — syntax,
    /// a constraint, a missing column, a permission on an object.
    ///
    /// **Never retried, and never treated as a reason to reconnect.** The connection is
    /// healthy; running the same statement on a new one produces the same refusal, and
    /// tearing down a working session over it would turn a typo into a reconnect.
    ///
    /// This is also the default for anything unclassified, which is the conservative
    /// choice on purpose: a driver that has not been taught to recognise its own
    /// transport failures reports them here, and the cost is that the user reconnects by
    /// hand — rather than the app deciding, on no evidence, to drop a live session.
    case statement

    /// The connection broke, or never formed. A reset socket, a refused port, a DNS
    /// failure, a TLS handshake that did not complete, a bastion that hung up.
    ///
    /// The only kind an automatic reconnect can fix, and therefore the only one that is
    /// allowed to trigger one.
    case transport

    /// Credentials were rejected, or a token that was valid has expired.
    ///
    /// Separate from ``transport`` precisely because reconnecting is *not* the answer: a
    /// new connection offering the same rejected credentials fails identically, and
    /// retrying on a backoff would lock an account out rather than recover it. What this
    /// needs is either the user or a token refresh, and both of those are somebody
    /// else's decision.
    case authentication

    /// No answer inside the window the caller allowed.
    ///
    /// Ambiguous by construction, and the ambiguity is the point: a timeout says the
    /// client stopped waiting, never that the server stopped working. The statement may
    /// still be running, still holding locks, and — on a metered warehouse — still being
    /// billed. So a timed-out run is never replayed even when it only read, because the
    /// replay would race the original rather than replace it.
    case timeout

    /// The caller stopped waiting on purpose, or the statement was killed on request.
    case cancelled

    /// Refused before anything was sent: a capability guard rail, or a configuration
    /// that is not filled in. Nothing reached a server, so nothing about the connection
    /// is in question.
    case unsupported

    /// Whether this failure means the session that produced it is no longer usable.
    ///
    /// Both arms leave a session that cannot serve the next query, and both should stop
    /// a pool handing the connection back out. They differ in what happens *next*, which
    /// is ``permitsAutomaticReconnect``'s question rather than this one's.
    public var invalidatesSession: Bool {
        switch self {
        case .transport, .authentication: true
        case .statement, .timeout, .cancelled, .unsupported: false
        }
    }

    /// Whether the app may reopen the connection without asking anyone.
    ///
    /// Only ``transport``. See ``authentication`` for why the other invalidating case is
    /// deliberately excluded.
    public var permitsAutomaticReconnect: Bool { self == .transport }

}

public struct QueryError: Error, Equatable, Sendable, Hashable {

    public static let cancelled = QueryError(message: "Query cancelled", kind: .cancelled)

    public static let disconnected = QueryError(message: "Disconnected", kind: .transport)

    public let message: String

    /// What can be done about this failure. See ``FailureKind``.
    ///
    /// Defaulted so that every existing `QueryError(message:)` — of which there are a
    /// great many, in six drivers and the app — keeps compiling and keeps meaning what
    /// it meant. A driver opts into the distinction by classifying; until it does, its
    /// errors are ``FailureKind/statement`` and the app treats them exactly as it always
    /// has.
    public let kind: FailureKind

    public init(message: String, kind: FailureKind = .statement) {
        self.message = message
        self.kind = kind
    }

}

public extension QueryError {

    /// The same failure, relabelled.
    ///
    /// For the wrappers — ``Session`` implementations that delegate and know something
    /// the driver underneath does not. `TunneledSession` is the standing example: the
    /// driver reports that the server hung up, and only the wrapper can tell that what
    /// actually died was the tunnel.
    func classified(as kind: FailureKind) -> QueryError {
        QueryError(message: message, kind: kind)
    }

    var isTransport: Bool { kind == .transport }

}
