//
//  Configuration.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public protocol Configuration: Sendable {
    var connectionString: String { get }
}

public protocol DatabaseConnectionConfig: Configuration {
    consuming func withDatabase(_ database: String?) -> Self
}

public struct FileConfiguration: Configuration, Sendable {

    public var path: String
    
    public var connectionString: String { path }
    
    public init(path: String) {
        self.path = path
    }

}
