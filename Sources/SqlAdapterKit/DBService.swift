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

    func query(_ query: String) throws (QueryError) {
        guard let adapter else { return }

        switch adapter.query(query) {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    mutating func disconnect() {
        adapter = nil
    }

}
