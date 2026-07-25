public protocol SqlTable: Identifiable, Sendable where ID == Int {
    associatedtype ID = Int
    var id: ID { get }
    var displayName: String { get }
    var queryName: String { get } // name to use in queries
}

public protocol SqlAdapter: Actor, Sendable {
    @concurrent func query(_ query: String) async throws(QueryError) -> QueryResult

    /// Persist any in-memory changes back to the adapter's backing file.
    ///
    /// Adapters that query a live database or write through SQL (e.g. DuckDB's
    /// `COPY ... TO`) don't need this and inherit the no-op default. Adapters
    /// that load a file into an in-memory table (SQLite CSV import) override it
    /// to serialise the table back to disk after `applyChanges`.
    func commitToFile() async throws(QueryError)
}

public extension SqlAdapter {
    func commitToFile() async throws(QueryError) {}
}
