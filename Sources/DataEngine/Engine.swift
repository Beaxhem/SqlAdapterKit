//
//  Engine.swift
//  DataEngine
//

import Foundation

/// Stable identity for an engine. Persisted on every saved connection, so it is a
/// migration hazard and must not be renamed once shipped.
public struct EngineIdentifier: Sendable, Hashable, RawRepresentable, ExpressibleByStringLiteral, Codable {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(stringLiteral value: String) { self.rawValue = value }

}

// MARK: - Catalog shape

/// One tier of a catalog — the things at one depth, and what to call them.
///
/// The names are per engine because the concept is: BigQuery's middle tier is a
/// dataset, Snowflake's is a schema, and calling both "database" in the sidebar is
/// wrong in a way users notice immediately.
public struct CatalogLevel: Sendable, Hashable {

    public let singular: String

    public let plural: String

    /// SF Symbol for a row at this tier.
    public let icon: String

    public init(singular: String, plural: String, icon: String) {
        self.singular = singular
        self.plural = plural
        self.icon = icon
    }

    public static let database = CatalogLevel(singular: "Database", plural: "Databases", icon: "externaldrive")
    public static let schema = CatalogLevel(singular: "Schema", plural: "Schemas", icon: "folder")
    public static let dataset = CatalogLevel(singular: "Dataset", plural: "Datasets", icon: "folder")
    public static let project = CatalogLevel(singular: "Project", plural: "Projects", icon: "cube")
    public static let table = CatalogLevel(singular: "Table", plural: "Tables", icon: "tablecells")

}

/// How deep an engine's catalog goes, and what each tier is called.
///
/// Replaces the two-valued `CatalogScope`, which could express "a list of databases"
/// and "a list of tables" and nothing else. Three of the four engines being added are
/// three tiers deep — project→dataset→table, database→schema→table — and the depth is
/// data here rather than structure, so a fourth tier would be a value and not a change.
public struct CatalogShape: Sendable {

    /// Container tiers, outermost first. Empty for a file-backed engine, where the
    /// connection *is* the database.
    public let containers: [CatalogLevel]

    /// What lives at the bottom tier, in the order the sidebar groups it.
    ///
    /// Was a single ``CatalogLevel``, which could only say "the leaf is called Table" —
    /// true of every engine and useful to none of them, because the question a sidebar
    /// actually has is *which* of the things down there to draw. Ordered rather than a
    /// set: this is also the order of the kind subheaders and of the menu that toggles
    /// them, and alphabetising "Functions" above "Tables" would be nobody's idea of an
    /// improvement.
    public let leafKinds: [CatalogObjectKind]

    public init(
        containers: [CatalogLevel] = [],
        leafKinds: [CatalogObjectKind] = [.table]
    ) {
        self.containers = containers
        self.leafKinds = leafKinds
    }

    /// The tier holding the things you can actually query, named after whichever kind
    /// the engine listed first.
    ///
    /// Kept because a great deal only wants the *label* — "Tables" in a breadcrumb, a
    /// section header — and does not care that there are six kinds under it.
    public var leaf: CatalogLevel { leafKinds.first?.level ?? .table }

    /// Number of path components a fully qualified leaf name has.
    public var depth: Int { containers.count + 1 }

    /// The tier at `depth`, counting from the outside; the leaf at the end.
    public func level(atDepth depth: Int) -> CatalogLevel {
        depth < containers.count ? containers[depth] : leaf
    }

    /// The same depth, listing different things.
    ///
    /// The presets below are shared by engines with nothing else in common — Postgres,
    /// MySQL and ClickHouse are all ``databases`` — and what each can enumerate at the
    /// bottom is exactly where they stop agreeing. This keeps the preset useful without
    /// making a preset per engine.
    public func listing(_ kinds: [CatalogObjectKind]) -> CatalogShape {
        CatalogShape(containers: containers, leafKinds: kinds)
    }

    /// What a connection shows before anyone has chosen, never empty.
    ///
    /// The fallback matters: an engine whose kinds are all opt-in would otherwise open
    /// to a blank sidebar and look broken rather than filtered.
    public var defaultVisibleKinds: Set<CatalogObjectKind.ID> {
        let visible = leafKinds.filter(\.isDefaultVisible)

        return Set((visible.isEmpty ? Array(leafKinds.prefix(1)) : visible).map(\.id))
    }

    /// The declared kind with this id, or nil for one this engine cannot list — which
    /// is how a visible-kind set saved against a different engine is discarded rather
    /// than drawn.
    public func kind(id: CatalogObjectKind.ID) -> CatalogObjectKind? {
        leafKinds.first { $0.id == id }
    }

    /// One file, one namespace: SQLite, DuckDB, CSV.
    public static let flat = CatalogShape()

    /// Server → database → table, with schemas folded into the table's own name.
    /// What Postgres and MySQL do today.
    public static let databases = CatalogShape(containers: [.database])

    /// Server → database → schema → table. Snowflake, and Redshift done properly.
    public static let databaseSchema = CatalogShape(containers: [.database, .schema])

    /// Project → dataset → table. BigQuery.
    public static let projectDataset = CatalogShape(containers: [.project, .dataset])

}

// MARK: - Descriptor

/// Everything the app needs to know about an engine before a connection to it exists.
///
/// This is what the six `ConnectionKind` switches collapse into. Each of them answered
/// a different question about the same enum — what to draw, what to call it, which
/// config class to make, which editor to show, which default port, which snippets —
/// and every one of them had to be revisited to add a case. They become lookups.
public struct EngineDescriptor: Sendable {

    public let id: EngineIdentifier

    public let displayName: String

    /// Short badge text where there is no icon asset — "Duck", "CH". Two to five
    /// characters; the sidebar draws it at 10pt.
    public let badge: String

    /// Name of an image set in the asset catalog, where the engine has real artwork.
    public let iconAssetName: String?

    public let catalog: CatalogShape

    /// What a connection to this engine can do *by default*. A session may report
    /// narrower capabilities once it knows what it actually connected to — a
    /// read-only role, a database attached read-only — and the session's answer wins.
    public let capabilities: EngineCapabilities

    public let settings: SettingsSchema

    /// Session state that is neither credential nor catalog position — see
    /// ``SessionContextField``. Empty for every engine that has none, which is all of
    /// them but Snowflake.
    public let sessionContext: [SessionContextField]

    public let executionModel: ExecutionModel

    public init(
        id: EngineIdentifier,
        displayName: String,
        badge: String,
        iconAssetName: String? = nil,
        catalog: CatalogShape,
        capabilities: EngineCapabilities,
        settings: SettingsSchema,
        sessionContext: [SessionContextField] = [],
        executionModel: ExecutionModel
    ) {
        self.id = id
        self.displayName = displayName
        self.badge = badge
        self.iconAssetName = iconAssetName
        self.catalog = catalog
        self.capabilities = capabilities
        self.settings = settings
        self.sessionContext = sessionContext
        self.executionModel = executionModel
    }

}

// MARK: - Engine

/// An engine the app can open connections to.
///
/// Deliberately tiny. Everything static about the engine is in ``descriptor``, so this
/// protocol has one job — turn a filled-in configuration into a live session — and a
/// new engine is a descriptor, a session and nothing else.
public protocol DatabaseEngine: Sendable {

    var descriptor: EngineDescriptor { get }

    /// Opens a connection.
    ///
    /// `async` unconditionally, which is the whole of the sync/async accommodation at
    /// this level: a blocking driver simply does not suspend. Where its work runs is
    /// ``EngineDescriptor/executionModel``'s business, not the caller's — see
    /// ``BlockingExecutor``.
    @concurrent func makeSession(_ settings: SettingsValues) async throws(QueryError) -> any Session

}

public extension DatabaseEngine {

    var id: EngineIdentifier { descriptor.id }

    /// Rejects a configuration the schema says is incomplete, naming the field.
    /// Called at the top of `makeSession` so a blank host fails as "Host is required"
    /// rather than as whatever the driver says when handed an empty string.
    func validate(_ settings: SettingsValues) throws(QueryError) {
        guard let missing = settings.firstMissingRequirement(of: descriptor.settings) else { return }

        throw QueryError(message: "\(missing.label) is required.")
    }

}

// MARK: - Registry

/// The engines this build knows about.
///
/// A value, built once at launch and passed down, rather than a global with
/// registration calls. Registration order would otherwise decide what the connection
/// picker lists, and "why is ClickHouse missing from the menu" would be a question
/// about static initialiser ordering.
public struct EngineRegistry: Sendable {

    /// In listing order — what the "new connection" menu shows, top to bottom.
    public let engines: [any DatabaseEngine]

    private let byIdentifier: [EngineIdentifier: any DatabaseEngine]

    public init(_ engines: [any DatabaseEngine]) {
        self.engines = engines
        self.byIdentifier = Dictionary(
            engines.map { ($0.descriptor.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public subscript(id: EngineIdentifier) -> (any DatabaseEngine)? {
        byIdentifier[id]
    }

    public func descriptor(for id: EngineIdentifier) -> EngineDescriptor? {
        byIdentifier[id]?.descriptor
    }

    /// Opens a connection, reporting an unknown engine as an error rather than a trap.
    ///
    /// The current code `fatalError`s on an unrecognised connection kind
    /// (`ConnectionConfig.hostConfig()`), which turns a stored config naming an engine
    /// this build no longer has — a downgrade, a removed driver — into a crash on
    /// launch. It is a config the user can delete, if they are shown it.
    @concurrent public func makeSession(
        engine id: EngineIdentifier,
        settings: SettingsValues
    ) async throws(QueryError) -> any Session {
        guard let engine = byIdentifier[id] else {
            throw QueryError(message: "This build has no “\(id.rawValue)” engine.")
        }

        return try await engine.makeSession(settings)
    }

}
