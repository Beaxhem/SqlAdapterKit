public protocol SqlAdapter {
    static func connect(configuration: Configuration) -> Result<Self, QueryError>

    func query(_ query: String) -> Result<[String], QueryError>
    func execute(_ query: String)
}
