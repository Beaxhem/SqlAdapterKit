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
}

public struct ExecutionInfo: Sendable {

    public let duration: TimeInterval

    public init(duration: TimeInterval) {
        self.duration = duration
    }

}

/// One executed query's columns and cells.
///
/// Immutable, in full: this is what the database returned. Pending inserts, edits
/// and deletes are a diff held by the editing overlay, and which rows are on screen
/// is the grid's own business — neither rewrites a result. Filtering therefore never
/// produces a second `QueryResult`; it produces a list of row indices.
public final class QueryResult: @unchecked Sendable {

    public static let empty = QueryResult(columns: [], store: .empty, executionInfo: .init(duration: 0))

    public let columns: [any Column]

    /// Every cell, addressed by `(row, column)`.
    public let store: RowStore

    public let executionInfo: ExecutionInfo

    public var rowCount: Int { store.rowCount }

    public var columnCount: Int { columns.count }

    /// Row cursors, produced on demand — see ``RowsView``.
    public var rows: RowsView { RowsView(store: store) }

    public init(columns: [any Column], store: RowStore, executionInfo: ExecutionInfo) {
        self.columns = columns
        self.store = store
        self.executionInfo = executionInfo
    }

    /// Builds a result from already-materialized rows. For mocks and tests; drivers
    /// go through ``QueryResultArenaBuilder`` instead.
    public convenience init(columns: [any Column], rows: [[GenericField]], executionInfo: ExecutionInfo) {
        self.init(
            columns: columns,
            store: RowStore(fields: rows.flatMap { $0 }, columnCount: columns.count),
            executionInfo: executionInfo
        )
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
