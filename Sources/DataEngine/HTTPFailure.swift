//
//  HTTPFailure.swift
//  DataEngine
//

import Foundation

/// Classifies the failures an HTTP-shaped driver sees.
///
/// Shared because ClickHouse and Snowflake reach their servers the same way — `URLSession`
/// over HTTP — and the interesting half of the mapping is `URLSession`'s rather than
/// either engine's. A lost connection is `URLError.networkConnectionLost` whichever
/// database was on the other end of it.
///
/// The half that is *not* shared is the status code, and the trap there is worth naming:
/// **ClickHouse reports ordinary SQL errors as HTTP 500.** A mapping that read the 5xx
/// range as "the server is broken" would classify every syntax error as a transport
/// failure and reconnect the session on each one. So the codes are listed individually
/// rather than by range.
public enum HTTPFailure {

    /// Whether a transport-level error means the connection is gone.
    ///
    /// `URLError` is the only structured thing `URLSession` offers, and it is a good one:
    /// these codes are set by the loading system rather than by the server, so they say
    /// what happened to the connection without anybody parsing prose.
    public static func kind(of error: some Error) -> FailureKind {
        guard let error = error as? URLError else {
            return error is CancellationError ? .cancelled : .statement
        }

        switch error.code {
        case .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .secureConnectionFailed,
             .cannotLoadFromNetwork,
             .internationalRoamingOff,
             .dataNotAllowed:
            return .transport

        case .timedOut:
            return .timeout

        case .cancelled:
            return .cancelled

        case .userAuthenticationRequired:
            return .authentication

        default:
            // Everything else — a bad URL, an unsupported scheme, a response the parser
            // rejected — is a fault in the request rather than in the link, and must not
            // put the session in question.
            return .statement
        }
    }

    /// What an HTTP status says about the connection.
    public static func kind(ofStatus status: Int) -> FailureKind {
        switch status {
        // Credentials rejected, or a token that has expired. Never retried on a timer.
        case 401, 403, 407:
            return .authentication

        case 408:
            return .timeout

        // The server is there but cannot serve this right now: a gateway with nothing
        // behind it, a node restarting behind a load balancer. A reconnect on a backoff is
        // the right response, which is what makes these transport rather than statement.
        case 502, 503:
            return .transport

        case 504:
            return .timeout

        default:
            // Everything else, **including 500**. See the note on the type: ClickHouse
            // answers a syntax error with a 500 and the message in the body, and treating
            // that as a broken server would reconnect the session on every typo.
            //
            // 429 lands here too, deliberately. Being rate limited is not a broken
            // connection, and tearing the session down would replace a message the user
            // can act on with a reconnect that cannot help.
            return .statement
        }
    }

}
