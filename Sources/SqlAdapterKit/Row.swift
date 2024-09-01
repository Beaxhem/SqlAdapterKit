//
//  Row.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public struct Field: Sendable, Hashable {
    public let type: UInt32
    public let value: String
    public let isNull: Bool

    public init(type: UInt32, value: String, isNull: Bool) {
        self.type = type
        self.value = value
        self.isNull = isNull
    }

}

public struct Row: @unchecked Sendable {

    public let data: [Field]

    public init(data: [Field]) {
        self.data = data
    }

}

open class Column: @unchecked Sendable, Identifiable {

    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

}

public struct QueryResult: Sendable {

    public nonisolated(unsafe) static let empty = QueryResult(columns: [], rows: [])

    public let columns: [Column]
    public let rows: [Row]

    public init(columns: [Column], rows: [Row]) {
        self.columns = columns
        self.rows = rows
    }

}
