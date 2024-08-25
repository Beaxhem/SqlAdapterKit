//
//  Configuration.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public struct Configuration {

    public private(set) var proto: String
    public private(set) var username: String
    public private(set) var password: String
    public private(set) var host: String
    public private(set) var port: Int
    public private(set) var database: String?

    public var connectionString: String {
        "\(proto)://\(username):\(password)@\(host):\(port)/\(database ?? "")"
    }

    public init(proto: String, username: String, password: String, host: String, port: Int, database: String?) {
        self.proto = proto
        self.username = username
        self.password = password
        self.host = host
        self.port = port
        self.database = database
    }

}
