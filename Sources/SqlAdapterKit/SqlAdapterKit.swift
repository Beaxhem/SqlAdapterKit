public protocol SqlAdapter {
    static func connect(configuration: Configuration) -> Result<Self, Error>

    func query(_ query: String) -> Result<[String], Error>
    func execute(_ query: String)
}

public struct DBService<Adapter: SqlAdapter> {

    let adapter: Adapter

    public init(adapter: Adapter) {
        self.adapter = adapter
    }

}

public extension DBService {

    func query(_ query: String) {
        let _ = adapter.query(query)
    }

}


