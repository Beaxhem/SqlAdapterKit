//
//  StatementSplitterTests.swift
//  DataEngineTests
//

import Testing
import Foundation
import DataEngine

/// ``StatementSplitter/executableStatements(in:)`` is the one genuinely new piece of
/// this file — the classification half is a port of `StatementSafety`, which has its
/// own tests in the app target.
///
/// It is also the piece that matters most to get right: a `.singleStatement` engine
/// sends what this returns, so an error here is not a wrong answer on screen, it is
/// the wrong SQL reaching a server.
@Suite("Statement splitting")
struct StatementSplitterTests {

    @Test("splits a plain script and drops the empties")
    func plainScript() {
        #expect(StatementSplitter.executableStatements(in: "SELECT 1; SELECT 2") == ["SELECT 1", "SELECT 2"])
        #expect(StatementSplitter.executableStatements(in: "SELECT 1;") == ["SELECT 1"])
        #expect(StatementSplitter.executableStatements(in: " ; ;SELECT 1;; ") == ["SELECT 1"])
        #expect(StatementSplitter.executableStatements(in: "").isEmpty)
    }

    /// The whole reason this cannot be `split(separator: ";")`.
    @Test("a semicolon inside a literal is not a statement break")
    func semicolonInLiteral() {
        #expect(StatementSplitter.executableStatements(in: "SELECT ';'") == ["SELECT ';'"])
        #expect(StatementSplitter.isSingleStatement("SELECT ';'"))

        #expect(
            StatementSplitter.executableStatements(in: "SELECT 'a;b'; SELECT 2")
                == ["SELECT 'a;b'", "SELECT 2"]
        )
    }

    @Test("a semicolon inside a comment is not a statement break")
    func semicolonInComment() {
        #expect(
            StatementSplitter.executableStatements(in: "SELECT 1 -- ; not a break\n; SELECT 2")
                == ["SELECT 1 -- ; not a break", "SELECT 2"]
        )

        #expect(
            StatementSplitter.executableStatements(in: "SELECT /* ; */ 1; SELECT 2")
                == ["SELECT /* ; */ 1", "SELECT 2"]
        )
    }

    /// The returned text is sent to a server, so it has to be the user's SQL and not
    /// the blanked copy the classifier works on. This is the failure the two-walk
    /// design exists to prevent.
    @Test("statements come back verbatim, not sanitized")
    func verbatim() {
        let sql = "INSERT INTO t VALUES ('it''s', \"quoted\", `back`) -- note\n; SELECT 1"
        let statements = StatementSplitter.executableStatements(in: sql)

        #expect(statements.count == 2)
        #expect(statements.first == "INSERT INTO t VALUES ('it''s', \"quoted\", `back`) -- note")
        #expect(statements.last == "SELECT 1")
    }

    @Test("an unterminated literal swallows the rest rather than splitting it")
    func unterminatedLiteral() {
        #expect(StatementSplitter.executableStatements(in: "SELECT 'oops; SELECT 2") == ["SELECT 'oops; SELECT 2"])
    }

    @Test("splitting agrees with counting")
    func agreesWithStatementCount() {
        let scripts = [
            "SELECT 1",
            "SELECT 1; SELECT 2",
            "SELECT ';'",
            "SELECT 1 -- ;\n; SELECT 2",
            "SELECT /* ; */ 1",
            "UPDATE t SET a = 'x;y' WHERE b = 1; DELETE FROM t"
        ]

        for script in scripts {
            #expect(
                StatementSplitter.executableStatements(in: script).count
                    == StatementSplitter.statements(in: script).count,
                "disagreed on: \(script)"
            )
        }
    }

    @Test("a write anywhere in a script makes the whole script a write")
    func readOnlyClassification() {
        #expect(StatementSplitter.isReadOnly("SELECT 1; SELECT 2"))
        #expect(!StatementSplitter.isReadOnly("SELECT 1; DELETE FROM t"))
        #expect(!StatementSplitter.isReadOnly("WITH x AS (SELECT 1) DELETE FROM t"))
        #expect(!StatementSplitter.isReadOnly(""))

        // A literal that reads like a keyword is a value, not a verb.
        #expect(StatementSplitter.isReadOnly("SELECT 'DELETE'"))
        #expect(StatementSplitter.isReadOnly("SELECT REPLACE(name, 'a', 'b') FROM t"))
        #expect(StatementSplitter.isReadOnly("SELECT insert_date FROM t"))
    }

}
