//
//  DBService.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public struct DBService<Adapter: SqlAdapter> {

    public var isConnected: Bool { adapter != nil }

    var adapter: Adapter?

    public init(adapter: Adapter) {
        self.adapter = adapter
    }

}

public extension DBService {

    func query(_ query: String) throws (QueryError) -> QueryResult {
        guard let adapter else { throw .init(message: "Not connected to database") }

        return try adapter.query(query)
    }

    mutating func disconnect() {
        adapter = nil
    }

}
