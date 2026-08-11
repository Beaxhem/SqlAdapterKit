//
//  StatementReloadabilityTests.swift
//  DataEngineTests
//
//  Created by Illia Senchukov on 04.08.2026.
//

import Testing
import DataEngine

@Suite("Statement reloadability")
struct StatementReloadabilityTests {

    @Test("Reads are reloadable", arguments: [
        "SELECT * FROM users",
        "  select id, name from users where id = 3  ",
        "SELECT * FROM users;",
        "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent",
        "SHOW TABLES",
        "EXPLAIN SELECT * FROM users",
        "VALUES (1), (2)",
        "SELECT\n  id\nFROM users",
    ])
    func readsAreReloadable(sql: String) {
        #expect(StatementSplitter.isReloadable(sql))
    }

    @Test("Writes are not reloadable", arguments: [
        "DELETE FROM users",
        "delete from users where id = 3",
        "INSERT INTO users (name) VALUES ('a')",
        "UPDATE users SET name = 'a'",
        "DROP TABLE users",
        "TRUNCATE TABLE users",
        "REPLACE INTO users (id) VALUES (1)",
        "CREATE TABLE t (id INT)",
        "ALTER TABLE users ADD COLUMN age INT",
        "VACUUM",
        "PRAGMA journal_mode = WAL",
        "CALL do_something()",
    ])
    func writesAreNotReloadable(sql: String) {
        #expect(!StatementSplitter.isReloadable(sql))
    }

    /// The cases a leading-keyword check alone gets wrong: a statement that reads as
    /// far as its first word and writes after it.
    @Test("Writes hidden behind a reading keyword are not reloadable", arguments: [
        "WITH gone AS (SELECT id FROM users WHERE stale) DELETE FROM users WHERE id IN (SELECT id FROM gone)",
        "WITH t AS (SELECT 1) INSERT INTO log SELECT * FROM t",
        "EXPLAIN ANALYZE DELETE FROM users",
        "SELECT * INTO archived_users FROM users",
    ])
    func hiddenWritesAreNotReloadable(sql: String) {
        #expect(!StatementSplitter.isReloadable(sql))
    }

    /// A script is only as safe as its worst statement — the split has to survive
    /// semicolons that are not statement separators.
    @Suite("Scripts")
    struct Scripts {

        @Test("A read cannot vouch for a write that follows it")
        func mixedScript() {
            #expect(!StatementSplitter.isReloadable("SELECT 1; DELETE FROM users"))
        }

        @Test("Every statement reading is reloadable")
        func allReads() {
            #expect(StatementSplitter.isReloadable("SELECT 1; SELECT 2;"))
        }

        @Test("A semicolon inside a literal does not start a statement")
        func semicolonInLiteral() {
            #expect(StatementSplitter.isReloadable("SELECT * FROM t WHERE note = 'a; DELETE FROM users'"))
        }

    }

    /// Words inside comments, literals and quoted identifiers are text, not keywords.
    @Suite("Sanitising")
    struct Sanitising {

        @Test("A literal that reads like a write is still a read")
        func writeInsideLiteral() {
            #expect(StatementSplitter.isReloadable("SELECT * FROM audit WHERE action = 'DELETE'"))
        }

        @Test("A quoted identifier that reads like a write is still a read")
        func writeInsideIdentifier() {
            #expect(StatementSplitter.isReloadable("SELECT \"delete\" FROM flags"))
        }

        @Test("A line comment is not part of the statement")
        func lineComment() {
            #expect(StatementSplitter.isReloadable("SELECT * FROM users -- DELETE FROM users"))
        }

        @Test("A block comment is not part of the statement")
        func blockComment() {
            #expect(StatementSplitter.isReloadable("SELECT /* DROP TABLE users */ * FROM users"))
        }

        @Test("A leading comment does not hide the leading keyword")
        func leadingComment() {
            #expect(StatementSplitter.isReloadable("-- daily check\nSELECT * FROM users"))
            #expect(!StatementSplitter.isReloadable("-- daily check\nDELETE FROM users"))
        }

        @Test("An escaped quote does not end the literal")
        func escapedQuote() {
            #expect(StatementSplitter.isReloadable("SELECT * FROM t WHERE s = 'it''s; DELETE FROM users'"))
        }

    }

    /// Keywords that only write when they lead, and are functions or column-name
    /// fragments everywhere else. Rejecting these would take ⌘R away from ordinary
    /// reads.
    @Suite("Not false positives")
    struct NotFalsePositives {

        @Test(arguments: [
            "SELECT REPLACE(name, 'a', 'b') FROM users",
            "SELECT TRUNCATE(price, 2) FROM items",
            "SELECT insert_date, delete_flag, update_count FROM audit",
            "SELECT * FROM users OFFSET 10",
        ])
        func stillReloadable(sql: String) {
            #expect(StatementSplitter.isReloadable(sql))
        }

    }

    @Suite("Nothing to run")
    struct NothingToRun {

        @Test(arguments: ["", "   ", ";", ";;", "-- just a note", "/* nothing */"])
        func isNotReloadable(sql: String) {
            #expect(!StatementSplitter.isReloadable(sql))
        }

        @Test("Unrecognised text is not reloadable")
        func unrecognised() {
            #expect(!StatementSplitter.isReloadable("wat"))
        }

    }

}
