//
//  HTTPFailureTests.swift
//  DataEngineTests
//

import Testing
import Foundation
import DataEngine

@Suite("HTTP failure classification")
struct HTTPFailureTests {

    /// The trap, and the reason the status codes are listed individually rather than by
    /// range: **ClickHouse answers an ordinary SQL error with HTTP 500** and the message
    /// in the body. Reading 5xx as "the server is broken" would classify every syntax
    /// error as a transport failure and tear the session down on each one.
    @Test("500 is a statement failure, because that is how ClickHouse reports SQL errors")
    func internalServerErrorIsAStatementFailure() {
        #expect(HTTPFailure.kind(ofStatus: 500) == .statement)
        #expect(!HTTPFailure.kind(ofStatus: 500).invalidatesSession)
    }

    /// A server that is there but cannot serve this right now — a gateway with nothing
    /// behind it, a node restarting behind a load balancer. Reconnecting on a backoff is
    /// what fixes these, which is what makes them transport.
    @Test("a gateway with nothing behind it is transport", arguments: [502, 503])
    func gatewayFailuresAreTransport(status: Int) {
        #expect(HTTPFailure.kind(ofStatus: status) == .transport)
    }

    @Test("a rejected or expired credential is authentication", arguments: [401, 403, 407])
    func authentication(status: Int) {
        #expect(HTTPFailure.kind(ofStatus: status) == .authentication)
        #expect(!HTTPFailure.kind(ofStatus: status).permitsAutomaticReconnect)
    }

    @Test("a gateway timeout is a timeout", arguments: [408, 504])
    func timeouts(status: Int) {
        #expect(HTTPFailure.kind(ofStatus: status) == .timeout)
    }

    /// Rate limiting is not a broken connection, and tearing the session down would
    /// replace a message the user can act on with a reconnect that cannot help.
    @Test("being rate limited does not put the connection in question")
    func rateLimiting() {
        #expect(!HTTPFailure.kind(ofStatus: 429).invalidatesSession)
    }

    @Test("an ordinary client error is a statement failure", arguments: [400, 404, 422])
    func clientErrors(status: Int) {
        #expect(HTTPFailure.kind(ofStatus: status) == .statement)
    }

    /// The half that is genuinely shared between the two HTTP engines: a lost connection
    /// is `URLSession`'s verdict, not the database's, and reads identically whichever
    /// server was on the other end.
    @Test(
        "a broken link is transport",
        arguments: [
            URLError.Code.networkConnectionLost,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .secureConnectionFailed
        ]
    )
    func brokenLinks(code: URLError.Code) {
        #expect(HTTPFailure.kind(of: URLError(code)) == .transport)
    }

    @Test("a timeout is a timeout, not a broken link")
    func timedOut() {
        // Distinct because the server may still be working on it — see
        // ``FailureKind/timeout``.
        #expect(HTTPFailure.kind(of: URLError(.timedOut)) == .timeout)
    }

    @Test("cancellation is not a failure of the connection")
    func cancellation() {
        #expect(HTTPFailure.kind(of: URLError(.cancelled)) == .cancelled)
        #expect(HTTPFailure.kind(of: CancellationError()) == .cancelled)
    }

    /// A fault in the request rather than in the link. Reconnecting cannot fix a URL the
    /// loading system refused to build.
    @Test("a malformed request does not put the connection in question")
    func requestFaults() {
        #expect(HTTPFailure.kind(of: URLError(.badURL)) == .statement)
        #expect(HTTPFailure.kind(of: URLError(.unsupportedURL)) == .statement)
    }

}
