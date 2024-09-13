public protocol SqlTable: Identifiable, Sendable {

    typealias ID = Int

    var tableSchema: String { get }
    var displayName: String { get }
    var queryName: String { get } // name to use in queries
}

public protocol SqlAdapter {
    static func connect(configuration: Configuration) async throws(QueryError) -> Self

    func query(_ query: String) throws(QueryError) -> QueryResult

    func fetchTables() throws(QueryError) -> [any SqlTable]
    func table(for column: any Column) -> (any SqlTable)?
}
