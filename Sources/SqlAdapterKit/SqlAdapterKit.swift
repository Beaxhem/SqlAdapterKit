public protocol SqlAdapter {
    static func connect(configuration: Configuration) -> Result<Self, QueryError>

    func query(_ query: String) -> Result<QueryResult, QueryError>
    func execute(_ query: String)

    func tableName(of column: any Column) -> Result<String, QueryError>
}
