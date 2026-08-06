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

    /// Runs `query`, reporting the rows as they arrive rather than only at the end.
    ///
    /// `onPartial` receives a result covering every row read so far, at most once per
    /// display frame, always with a row count greater than the last — a result grows
    /// by appending, so a row index means the same thing in every one of them. The
    /// final result is still the return value, and a caller that ignores `onPartial`
    /// entirely sees exactly the buffered behaviour.
    ///
    /// Only meaningful for a **single statement**. A script's later statement can
    /// supersede an earlier one's rows (see `PostgresConnection.query`), and rows
    /// already handed over cannot be taken back, so callers must not ask for a
    /// streamed run of a multi-statement string.
    ///
    /// Adapters that have nothing to gain — or no way to read rows before the end —
    /// inherit the default, which simply runs the buffered query.
    @concurrent func query(
        _ query: String,
        onPartial: @escaping @Sendable (QueryResult) -> Void
    ) async throws(QueryError) -> QueryResult

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

    /// Nothing is reported early: the caller gets the whole result as the return
    /// value, which is what it would have got from ``query(_:)``. Deliberately not a
    /// single `onPartial` call with the finished result — that would be a second
    /// delivery of something the caller is already about to receive.
    @concurrent func query(
        _ query: String,
        onPartial: @escaping @Sendable (QueryResult) -> Void
    ) async throws(QueryError) -> QueryResult {
        // `self.` is load-bearing: the parameter shadows the method.
        try await self.query(query)
    }
}
