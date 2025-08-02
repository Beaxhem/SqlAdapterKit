//
//  QueryError.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public struct QueryError: Error, Equatable, Sendable, Hashable {

    public static let cancelled = QueryError(message: "Query cancelled")

    public static let disconnected = QueryError(message: "Disconnected")

    public let message: String

    public init(message: String) {
        self.message = message
    }

}
