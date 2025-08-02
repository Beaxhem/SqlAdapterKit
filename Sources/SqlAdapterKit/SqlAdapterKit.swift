public protocol SqlTable: Identifiable, Sendable where ID == Int {
    associatedtype ID = Int
    var id: ID { get }
    var displayName: String { get }
    var queryName: String { get } // name to use in queries
}

public protocol SqlAdapter: Actor, Sendable {
    @concurrent func query(_ query: String) async throws(QueryError) -> QueryResult
}
