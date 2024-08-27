//
//  Configuration.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

public struct Configuration {

    public var proto: String
    public var username: String
    public var password: String
    public var host: String
    public var port: Int16
    public var database: String?

    public var connectionString: String {
        "\(proto)://\(username):\(password)@\(host):\(port)/\(database ?? "")"
    }

    public init(proto: String, username: String, password: String, host: String, port: Int16, database: String?) {
        self.proto = proto
        self.username = username
        self.password = password
        self.host = host
        self.port = port
        self.database = database
    }

}
