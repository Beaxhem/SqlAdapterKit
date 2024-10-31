public protocol SqlTable: Identifiable, Sendable where ID == Int {
    var id: ID { get }
    var displayName: String { get }
    var queryName: String { get } // name to use in queries
}

public protocol SqlAdapter: Actor, Sendable {
    func query(_ query: String) async throws(QueryError) -> QueryResult

    func fetchTables() async throws(QueryError) -> [any SqlTable]
    func table(for column: any Column) -> (any SqlTable)?

    func primaryKeys(for table: any SqlTable) async throws(QueryError) -> Set<String>? // returns column names
}

public protocol MetaInfoProvidingAdapter: SqlAdapter {
    func reloadMetaInfo() async throws(QueryError)
}
