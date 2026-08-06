//
//  QueryResult.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public protocol Column: Sendable, Identifiable where ID == Int {
    var id: ID { get } // should be the index of column in results
    var name: String { get }
    var type: GenericType { get }

    /// The table this column is selected from, or nil when it has no single backing
    /// one — an expression, a literal, or a driver that can't attribute columns for
    /// the query at hand. A nil owner is what makes a column read-only downstream.
    var owner: TableKey? { get }
}

public extension Column {

    /// Columns that never come from a table (mocks, synthetic results) inherit this.
    var owner: TableKey? { nil }

}

public struct ExecutionInfo: Sendable {

    public let duration: TimeInterval

    public init(duration: TimeInterval) {
        self.duration = duration
    }

}

/// What a statement that returned no result set did.
///
/// Carried on ``QueryResult/command``, and non-nil exactly when the database answered
/// with a command tag rather than a row set — an UPDATE, an INSERT, any DDL. That is a
/// distinction nothing downstream can infer: a SELECT that matched nothing also has no
/// rows, but it has columns, and a grid with headers and no rows is a truthful account
/// of it. A write has neither, so an unqualified result renders as a grid of nothing.
public struct CommandSummary: Sendable {

    /// What the statement was, as the driver names it — "UPDATE", "CREATE TABLE".
    /// nil where the driver gives nothing to name it with.
    public let tag: String?

    /// Rows the statement touched, or nil where it does not report one — which is not
    /// the same as zero and must not be shown as zero. DDL reports nothing; an UPDATE
    /// that matched nothing reports 0, and that is worth saying.
    public let affectedRows: Int?

    public init(tag: String?, affectedRows: Int?) {
        self.tag = tag
        self.affectedRows = affectedRows
    }

}

/// One executed query's columns and cells.
///
/// Immutable, in full: this is what the database returned. Pending inserts, edits
/// and deletes are a diff held by the editing overlay, and which rows are on screen
/// is the grid's own business — neither rewrites a result. Filtering therefore never
/// produces a second `QueryResult`; it produces a list of row indices.
public final class QueryResult: @unchecked Sendable {

    /// No result set and nothing said about why. Only for a run that produced nothing at
    /// all — a statement that *did* something reports it through ``command`` instead.
    public static let empty = QueryResult(columns: [], store: .empty, executionInfo: .init(duration: 0))

    public let columns: [any Column]

    /// Every cell, addressed by `(row, column)`.
    public let store: RowStore

    public let executionInfo: ExecutionInfo

    /// Set when the statement returned no result set — see ``CommandSummary``. Mutually
    /// exclusive with having columns in practice, though nothing enforces it: the drivers
    /// build one or the other.
    public let command: CommandSummary?

    /// Whether this is a write or a DDL rather than a table. What the grid, the search
    /// bar and the chart builder have no business being offered for.
    public var isCommand: Bool { command != nil }

    public var rowCount: Int { store.rowCount }

    public var columnCount: Int { columns.count }

    /// Row cursors, produced on demand — see ``RowsView``.
    public var rows: RowsView { RowsView(store: store) }

    public init(
        columns: [any Column],
        store: RowStore,
        executionInfo: ExecutionInfo,
        command: CommandSummary? = nil
    ) {
        self.columns = columns
        self.store = store
        self.executionInfo = executionInfo
        self.command = command
    }

    /// Builds a result from already-materialized rows. For mocks and tests; drivers
    /// go through ``StreamingResultBuilder`` instead.
    public convenience init(columns: [any Column], rows: [[GenericField]], executionInfo: ExecutionInfo) {
        self.init(
            columns: columns,
            store: RowStore(fields: rows.flatMap { $0 }, columnCount: columns.count),
            executionInfo: executionInfo
        )
    }

    /// The outcome of a statement that returned no rows.
    public static func command(_ summary: CommandSummary, executionInfo: ExecutionInfo) -> QueryResult {
        .init(columns: [], store: .empty, executionInfo: executionInfo, command: summary)
    }

    public subscript(row: Int, column: Int) -> GenericField {
        store.field(row: row, column: column)
    }

    public func value(row: Int, column: Int) -> String? {
        store.value(row: row, column: column)
    }

}

public enum TypeCategory: Equatable, Sendable {
    case integer, float
    case nchar, varchar, text
    case binary
    case date, time, datetime, interval
    case boolean
    case enumeration
    case xml, json
    case spatial
    case array
    case userDefined
    case system
    case unknown
}

public protocol SqlType {
    var name: String { get }
    var genericType: GenericType { get }
}

public struct GenericType: Sendable {

    public let name: String
    public let category: TypeCategory

    public init(name: String, category: TypeCategory) {
        self.name = name
        self.category = category
    }

}
