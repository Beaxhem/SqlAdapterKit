//
//  Row.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public struct Field: Hashable {
    public let type: UInt32
    public let value: String
    public let isNull: Bool

    public init(type: UInt32, value: String, isNull: Bool) {
        self.type = type
        self.value = value
        self.isNull = isNull
    }

}

public struct Row: Identifiable, Hashable {

    public var id: UInt32 {
        idx
    }

    public let idx: UInt32
    public let columns: [String]
    public var data: [Field]

    public init(idx: UInt32, columns: [String], data: [Field]) {
        self.idx = idx
        self.columns = columns
        self.data = data
    }

}

public struct Column: Identifiable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

}

public struct QueryResult {

    public nonisolated(unsafe) static let empty = QueryResult(columns: [], rows: [])

    public let columns: [Column]
    public let rows: [Row]

    public init(columns: [String], rows: [Row]) {
        self.columns = columns.enumerated().map { .init(id: $0, name: $1) }
        self.rows = rows
    }
}
