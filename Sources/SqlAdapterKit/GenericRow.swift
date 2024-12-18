//
//  Row.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public struct GenericField: @unchecked Sendable, Equatable {

    public var value: String?

    public init(value: String?) {
        self.value = value
    }

    public static func == (lhs: GenericField, rhs: GenericField) -> Bool {
        lhs.value == rhs.value
    }

}

public final class GenericRow: @unchecked Sendable, Identifiable {

    public typealias ID = Int

    public let id: ID
    public var data: [GenericField]

    public init(id: ID, data: [GenericField]) {
        self.id = id
        self.data = data
    }

}

public protocol Column: Sendable, Identifiable where ID == Int {
    var id: ID { get } // should be the index of column in results
    var name: String { get }
    var type: GenericType { get }
}

public final class QueryResult: @unchecked Sendable {

    public static let empty = QueryResult(columns: [], rows: [])

    public let columns: [any Column]
    public var rows: [GenericRow]

    public init(columns: [any Column], rows: [GenericRow]) {
        self.columns = columns
        self.rows = rows
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
