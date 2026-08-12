//
//  Transaction.swift
//  DataEngine
//

import Foundation

/// How one engine spells a transaction.
///
/// Only `begin` actually varies — `COMMIT` and `ROLLBACK` are the same word everywhere
/// this app connects to — but they travel together, and a driver that had to remember
/// two of the three from the shared helper and supply the third itself would be one
/// edit away from rolling back with a keyword its server does not take.
public struct TransactionSyntax: Sendable {

    public var begin: String

    public var commit: String

    public var rollback: String

    public init(begin: String, commit: String = "COMMIT", rollback: String = "ROLLBACK") {
        self.begin = begin
        self.commit = commit
        self.rollback = rollback
    }

    /// SQLite and DuckDB.
    public static let standard = TransactionSyntax(begin: "BEGIN")

    /// MySQL. `BEGIN` is accepted too, but it is also the opening of a compound
    /// statement, and the documented spelling is the one that cannot be read twice.
    public static let mysql = TransactionSyntax(begin: "START TRANSACTION")

    /// `script`, bracketed so the engine runs all of it or none of it.
    ///
    /// One string, sent in one request, rather than three round trips. Not only for the
    /// two it saves: a driver that sent `BEGIN` on its own would have to suspend before
    /// the body, and on the single-connection engines a suspension is where somebody
    /// else's statement gets in — running inside a transaction it knows nothing about
    /// and committing with it.
    /// Ends on the `COMMIT` with nothing after it. A driver that splits a script itself
    /// has to decide what a trailing newline is, and one of them decided it was another
    /// statement — so this leaves it with nothing to decide.
    public func bracketing(_ script: String) -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminated = trimmed.hasSuffix(";") ? trimmed : trimmed + ";"

        return "\(begin);\n\(terminated)\n\(commit);"
    }

}

/// Runs `script` as a transaction, rolling back if it fails.
///
/// The rollback is the whole point, and it is why this cannot live at the call site that
/// wanted the transaction: it has to reach the same connection the statements ran on,
/// which — behind a pool — is knowledge that exists only for the duration of the
/// driver's borrow. A `BEGIN` sent without one leaves the connection inside an open
/// transaction, holding locks on MySQL and refusing every later statement on Postgres,
/// and hands it back to the pool looking healthy.
///
/// - Parameters:
///   - rollback: runs one statement on the *same* connection `run` used.
///   - run: runs the bracketed script it is given.
///
/// A failed rollback is swallowed: the error worth reporting is the one that broke the
/// script, not the second one that came of trying to tidy up after it. It usually means
/// the connection is gone, in which case the server has already rolled the transaction
/// back on its own — but a pool holding such a connection will hand it out again, which
/// is a wider problem than this function and not one it should paper over by inventing a
/// different error.
public func withTransaction<R>(
    _ script: String,
    syntax: TransactionSyntax = .standard,
    rollback: (String) async throws(QueryError) -> Void,
    run: (String) async throws(QueryError) -> R
) async throws(QueryError) -> R {
    do {
        return try await run(syntax.bracketing(script))
    } catch {
        try? await rollback(syntax.rollback)

        throw error
    }
}
