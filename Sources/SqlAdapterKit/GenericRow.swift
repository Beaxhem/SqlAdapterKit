//
//  Row.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public final class GenericField: @unchecked Sendable {

    public let type: UInt32
    public var value: String?

    public init(type: UInt32, value: String?) {
        self.type = type
        self.value = value
    }

    public func copy() -> Self {
        .init(type: type, value: value)
    }

}

public final class GenericRow: @unchecked Sendable {

    public typealias ID = Int

    public let id: ID
    public var data: [GenericField]

    public init(id: ID, data: [GenericField]) {
        self.id = id
        self.data = data
    }

}

public protocol Column: Sendable, Identifiable {
    var id: Int { get } // should be the index of column in results
    var name: String { get }
}

public final class QueryResult: @unchecked Sendable {

    public nonisolated(unsafe) static let empty = QueryResult(columns: [], rows: [])

    public let columns: [any Column]
    public var rows: [GenericRow]

    public init(columns: [any Column], rows: [GenericRow]) {
        self.columns = columns
        self.rows = rows
    }

}
