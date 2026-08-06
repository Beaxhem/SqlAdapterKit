//
//  CommandTag.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 06.08.2026.
//

import Foundation

public extension CommandSummary {

    /// A summary for a driver that counts rows but never says what it ran.
    ///
    /// libpq hands back its own command tag; SQLite and MySQL hand back a number and
    /// nothing else, so the verb has to be read off the statement itself. Deliberately
    /// shallow — this is a label for one line of a screen, not a parser — and what it
    /// cannot name confidently it leaves unnamed rather than guessing at.
    ///
    /// `affectedRows` is dropped for a statement whose verb does not report rows. DDL
    /// says nothing about them and both drivers count zero for it, which on screen
    /// would read as "changed nothing" rather than "not applicable".
    static func forStatement(_ sql: String, affectedRows: Int?) -> CommandSummary {
        let tag = commandTag(for: sql)

        return .init(tag: tag, affectedRows: countsRows(tag) ? affectedRows : nil)
    }

    /// Whether a statement introduced by `tag` reports a row count at all.
    static func countsRows(_ tag: String?) -> Bool {
        guard let verb = tag?.prefix(while: { !$0.isWhitespace }) else { return false }

        return rowCountingVerbs.contains(String(verb))
    }

}

/// Verbs that touch rows and therefore have a count worth printing. Everything else
/// gets no figure at all rather than a zero.
private let rowCountingVerbs: Set<String> = ["INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "UPSERT"]

/// Verbs that say nothing on their own — "CREATE" does not tell the reader what was
/// created — so the thing they act on is read too.
private let objectTakingVerbs: Set<String> = ["CREATE", "DROP", "ALTER", "TRUNCATE"]

/// What can sit between such a verb and its object: `CREATE OR REPLACE VIEW`,
/// `CREATE UNIQUE INDEX`, `DROP TABLE IF EXISTS`.
private let fillerWords: Set<String> = [
    "OR", "REPLACE", "TEMP", "TEMPORARY", "UNIQUE", "IF", "NOT", "EXISTS",
    "MATERIALIZED", "VIRTUAL", "GLOBAL", "LOCAL", "DEFINER", "ONLINE"
]

/// The leading verb of a statement, and its object where the verb needs one.
///
/// nil where the first word is not a plain word — a parenthesised statement, or one
/// starting with anything this does not recognise as a verb. The caller shows a neutral
/// line in that case, which is what an unrecognised statement deserves.
private func commandTag(for sql: String) -> String? {
    let words = leadingWords(of: sql)

    guard let verb = words.first, verb.allSatisfy(\.isLetter) else { return nil }

    guard objectTakingVerbs.contains(verb) else { return verb }

    guard let object = words.dropFirst().first(where: { !fillerWords.contains($0) }),
          object.allSatisfy(\.isLetter) else {
        return verb
    }

    return "\(verb) \(object)"
}

/// The first few words of a statement, uppercased, with anything in front of them that
/// is not the statement — leading whitespace and comments — skipped first. A statement
/// under a `-- note` is still an UPDATE.
private func leadingWords(of sql: String, limit: Int = 6) -> [String] {
    var rest = Substring(sql)

    while true {
        rest = rest.drop(while: \.isWhitespace)

        if rest.hasPrefix("--") {
            rest = rest.drop(while: { !$0.isNewline })
        } else if rest.hasPrefix("/*"), let close = rest.range(of: "*/") {
            rest = rest[close.upperBound...]
        } else {
            break
        }
    }

    // Bounded before splitting: a statement can be a megabyte of VALUES, and the verb
    // is in the first handful of characters of it either way.
    return rest
        .prefix(200)
        .split(whereSeparator: \.isWhitespace)
        .prefix(limit)
        .map { $0.uppercased() }
}
