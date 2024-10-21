public protocol SqlTable: Identifiable, Sendable {

    typealias ID = Int

    var id: ID { get }
    var tableSchema: String { get }
    var displayName: String { get }
    var queryName: String { get } // name to use in queries
}

public protocol MetaInfo: Sendable {
    func reload() async
}

public protocol SqlAdapter: Sendable {
    static func connect(configuration: Configuration) async throws(QueryError) -> Self

    func query(_ query: String, metaInfo: MetaInfo?) async throws(QueryError) -> QueryResult
    func metaInfo() async throws(QueryError) -> MetaInfo

    func fetchTables(meta: MetaInfo?) throws(QueryError) -> [any SqlTable]
    func table(for column: any Column, meta: MetaInfo?) -> (any SqlTable)?

    func primaryKeys(for table: any SqlTable, meta: MetaInfo?) -> Set<String>? // returns column names
}
