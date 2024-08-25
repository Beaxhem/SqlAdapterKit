//
//  QueryError.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public struct QueryError: Error {

    public var message: String

    public init(message: String) {
        self.message = message
    }

}
