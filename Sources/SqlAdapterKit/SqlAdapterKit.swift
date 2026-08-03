/// Identity of the table a column was selected from.
///
/// Drivers report a column's origin in whatever form their protocol gives them —
/// Postgres a `pg_class` oid, everyone else a bare name — and the app resolves that
/// against the catalog it fetched. Keeping both cases in one type is what lets table
/// resolution be written once instead of once per driver.
///
/// `.oid` is only ever resolvable through the catalog: an oid carries no name, so a
/// column whose oid is absent from it cannot be attributed. `.name` can be resolved
/// without one, which is why the name-based drivers keep attributing columns before
/// the first catalog load lands.
public enum TableKey: Hashable, Sendable {
    case oid(UInt32)
    case name(String)
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
