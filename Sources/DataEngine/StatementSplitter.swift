//
//  StatementSplitter.swift
//  DataEngine
//

import Foundation

/// Splits SQL into statements, and answers what they would do.
///
/// Moved down from the app, where it was `StatementSafety`, because three things below
/// the app now need it and one of them is not optional: an engine declaring
/// ``ScriptingSupport/singleStatement`` has to split a script to run it at all, and a
/// connection declaring ``MutationSupport/readOnly`` has to be able to tell a read from
/// a write before it sends one.
///
/// Deliberately not a parser. It answers coarse questions conservatively, and anything
/// it does not recognise it treats as a write. The cost of a wrong answer is
/// asymmetric: a false negative costs a refresh the user can still ask for by hand, a
/// false positive runs a mutation nobody asked for.
public enum StatementSplitter {}

public extension StatementSplitter {

    /// The statements in `sql`, with comments and quoted runs already neutralised.
    static func statements(in sql: String) -> [String] {
        sanitized(sql)
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The statements in `sql` **as written**, ready to send.
    ///
    /// ``statements(in:)`` returns the sanitized text, which is fine for classifying
    /// but not for executing — every string literal in it has been replaced by a
    /// space. This splits the original at the offsets the sanitized pass found, so a
    /// `.singleStatement` engine sends the user's SQL rather than a blanked copy of it.
    static func executableStatements(in sql: String) -> [String] {
        let characters = Array(sql)
        let mask = Array(sanitized(sql))

        // The sanitizer replaces each comment and quoted run with exactly one space,
        // so the mask is shorter than the source and offsets do not line up. Walk both.
        var statements: [String] = []
        var current = ""
        var index = 0
        var maskIndex = 0

        while index < characters.count {
            let span = sanitizedSpan(characters, from: index)

            if span.length > 1 || span.isSeparator {
                // A comment or a literal: copied through verbatim, and never a break.
                current.append(contentsOf: characters[index..<(index + span.length)])
                index += span.length
                maskIndex += 1
                continue
            }

            if maskIndex < mask.count, mask[maskIndex] == ";" {
                statements.append(current)
                current = ""
            } else {
                current.append(characters[index])
            }

            index += 1
            maskIndex += 1
        }

        statements.append(current)

        return statements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// True when `sql` is exactly one statement.
    ///
    /// Asked before requesting a streamed run, and by ``Session/validate(_:)`` for an
    /// engine that takes one statement per request. Rows reported early cannot be taken
    /// back, and in a script a later statement supersedes an earlier one's result.
    static func isSingleStatement(_ sql: String) -> Bool {
        statements(in: sql).count == 1
    }

    /// True when every statement in `sql` only reads.
    ///
    /// Every one, because a leading `SELECT 1;` must not vouch for the `DELETE` that
    /// follows it.
    static func isReadOnly(_ sql: String) -> Bool {
        let statements = statements(in: sql)

        guard !statements.isEmpty else { return false }

        return statements.allSatisfy(isStatementReadOnly)
    }

    /// Whether re-running `sql` on the user's behalf is safe — ⌘R, and the reload that
    /// follows an apply. Neither is a run the user typed and pressed ↩ on, so neither
    /// may execute a statement that writes: "refreshing" `DELETE FROM users` deletes a
    /// second time.
    static func isReloadable(_ sql: String) -> Bool {
        isReadOnly(sql)
    }

}

// MARK: - Classification

private extension StatementSplitter {

    /// Leading keywords that introduce a statement which reads.
    ///
    /// `PRAGMA` is absent on purpose: `PRAGMA journal_mode = WAL` writes, and its read
    /// and write forms differ only by an assignment.
    static let readingKeywords: Set<String> = [
        "SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "VALUES", "TABLE"
    ]

    /// Keywords that make a statement write, wherever in it they appear.
    ///
    /// Scanned across the whole statement rather than just its first word, because a
    /// reading keyword can lead a writing statement: `WITH x AS (…) DELETE FROM …`,
    /// `EXPLAIN ANALYZE UPDATE …`, `SELECT … INTO new_table`.
    ///
    /// `REPLACE` and `TRUNCATE` are absent although both write — as `REPLACE INTO` and
    /// `TRUNCATE TABLE`, which is to say only when they lead, where the check on the
    /// leading keyword already rejects them. Listing them here would instead reject
    /// `SELECT REPLACE(name, 'a', 'b')` and MySQL's `TRUNCATE(x, 2)`, which are
    /// functions and appear in ordinary reads.
    static let writingKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "INTO",
        "CREATE", "DROP", "ALTER", "RENAME", "REINDEX", "CLUSTER", "REFRESH",
        "GRANT", "REVOKE", "VACUUM", "ANALYZE", "ATTACH", "DETACH", "COPY",
        "SET", "CALL", "EXEC", "EXECUTE", "PRAGMA",
        "BEGIN", "START", "COMMIT", "ROLLBACK", "LOCK"
    ]

    static func isStatementReadOnly(_ statement: String) -> Bool {
        let words = words(in: statement)

        guard let leading = words.first, readingKeywords.contains(leading) else {
            return false
        }

        return !words.contains(where: writingKeywords.contains)
    }

    /// The statement's words, uppercased. Underscores are word characters, so a column
    /// named `insert_date` is one word and never matches `INSERT`.
    static func words(in statement: String) -> [String] {
        statement
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map { $0.uppercased() }
    }

}

// MARK: - Sanitizing

private extension StatementSplitter {

    /// One run of source that the sanitizer collapses.
    struct Span {
        /// Characters consumed from the source.
        let length: Int
        /// Whether it was collapsed to a space rather than copied through.
        let isSeparator: Bool

        static let single = Span(length: 1, isSeparator: false)
    }

    /// Replaces every comment and quoted run with a space.
    ///
    /// Runs before the split on `;`, so a semicolon inside a string cannot manufacture
    /// a second statement, and before the words are counted, so neither a value that
    /// reads `'DELETE'` nor a column quoted as `"delete"` can make a plain `SELECT`
    /// look like a write.
    static func sanitized(_ sql: String) -> String {
        let characters = Array(sql)
        var output = ""
        output.reserveCapacity(characters.count)

        var index = 0
        while index < characters.count {
            let span = sanitizedSpan(characters, from: index)

            if span.isSeparator {
                output.append(" ")
            } else {
                output.append(contentsOf: characters[index..<(index + span.length)])
            }

            index += span.length
        }

        return output
    }

    /// Classifies the run starting at `index`: a comment, a quoted literal, or one
    /// ordinary character.
    ///
    /// Factored out so ``sanitized(_:)`` and ``executableStatements(in:)`` walk the
    /// source by exactly the same rules. They disagreed once, which is how a semicolon
    /// inside a literal became a statement break on one path and not the other.
    static func sanitizedSpan(_ characters: [Character], from index: Int) -> Span {
        let character = characters[index]
        let next = index + 1 < characters.count ? characters[index + 1] : nil

        if (character == "-" && next == "-") || character == "#" {
            return Span(length: endOfLine(characters, from: index) - index, isSeparator: true)
        }

        if character == "/" && next == "*" {
            return Span(length: endOfBlockComment(characters, from: index) - index, isSeparator: true)
        }

        if character == "'" || character == "\"" || character == "`" {
            let end = endOfQuoted(characters, from: index, quote: character)
            return Span(length: end - index, isSeparator: true)
        }

        return .single
    }

    static func endOfLine(_ characters: [Character], from index: Int) -> Int {
        var index = index

        while index < characters.count, !characters[index].isNewline {
            index += 1
        }

        return index
    }

    static func endOfBlockComment(_ characters: [Character], from index: Int) -> Int {
        var index = index + 2

        while index + 1 < characters.count {
            if characters[index] == "*", characters[index + 1] == "/" {
                return index + 2
            }

            index += 1
        }

        return characters.count
    }

    /// Past the closing quote, or to the end where there is none. Swallowing the rest
    /// of an unterminated literal is the conservative reading: the statement will not
    /// parse anyway, and what follows is not keywords.
    static func endOfQuoted(_ characters: [Character], from index: Int, quote: Character) -> Int {
        var index = index + 1

        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                index += 2
                continue
            }

            if characters[index] == quote {
                // A doubled quote is an escaped quote, not the end of the literal.
                if index + 1 < characters.count, characters[index + 1] == quote {
                    index += 2
                    continue
                }

                return index + 1
            }

            index += 1
        }

        return characters.count
    }

}
