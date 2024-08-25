public protocol SqlAdapter {
    static func connect(configuration: Configuration) -> Result<Self, QueryError>

    func query(_ query: String) -> Result<[String], QueryError>
    func execute(_ query: String)
}

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

public struct QueryError: Error {

    public var message: String

    public init(message: String) {
        self.message = message
    }

}
