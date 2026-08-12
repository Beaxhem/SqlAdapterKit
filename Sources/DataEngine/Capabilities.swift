//
//  Capabilities.swift
//  DataEngine
//

import Foundation

/// What an engine can be asked to do.
///
/// Every place the app used to reach for a `ConnectionKind` and switch on it belongs
/// here instead. The distinction matters more than it looks: `ConnectionKind` answers
/// "which engine is this", which is never the question a call site actually has. A
/// grid does not want to know it is talking to BigQuery, it wants to know whether it
/// may offer an editable cell — and the moment a sixth engine appears, every switch
/// that answered the first question has to be revisited while every one that answered
/// the second does not.
///
/// Declared per *connection* rather than per engine, because it is not always a
/// property of the engine: a Postgres connection opened by a read-only role, or a
/// DuckDB database attached read-only, has narrower capabilities than the driver.
public struct EngineCapabilities: Sendable {

    /// Whether, and how, rows may be written back.
    public var mutation: MutationSupport

    /// Whether results are rectangular or one self-describing document per row.
    public var schema: SchemaModel

    /// Whether the driver accepts more than one statement per request.
    public var scripting: ScriptingSupport

    /// Whether a request can be made all-or-nothing, and who has to arrange it.
    public var transactions: TransactionSupport

    /// How an in-flight query is called off — and whether it can be at all.
    public var cancellation: CancellationSupport

    /// Whether a result arrives whole or in windows the caller must ask for.
    public var pagination: PaginationModel

    /// Whether running a query spends money.
    public var cost: CostModel

    /// How the engine treats an unquoted identifier, which is what decides whether a
    /// name fetched from the catalog can be compared against one the user typed.
    public var identifierFolding: IdentifierFolding

    public init(
        mutation: MutationSupport,
        schema: SchemaModel = .rectangular,
        scripting: ScriptingSupport = .singleStatement,
        transactions: TransactionSupport = .none,
        cancellation: CancellationSupport = .none,
        pagination: PaginationModel = .wholeResult,
        cost: CostModel = .free,
        identifierFolding: IdentifierFolding = .preserve
    ) {
        self.mutation = mutation
        self.schema = schema
        self.scripting = scripting
        self.transactions = transactions
        self.cancellation = cancellation
        self.pagination = pagination
        self.cost = cost
        self.identifierFolding = identifierFolding
    }

}

// MARK: - Mutation

/// Which mutations the app may build for a connection, and on what evidence it may
/// identify the row to apply them to.
///
/// The middle case is the one that exists for a reason. When a table declares no
/// primary key, the planner identifies a row by matching every column it selected —
/// tolerable against a dev table, catastrophic against a warehouse fact table, where
/// the filter is both unbearably expensive and not guaranteed to name one row. An
/// engine that reports no keys and cannot be probed cheaply should say `.keyed`, and
/// the fallback is then structurally unavailable rather than merely discouraged.
public enum MutationSupport: Sendable, Equatable {

    /// The grid is a viewer. No cell editor, no insert row, no delete, no DDL.
    case readOnly

    /// Rows may be mutated only where the catalog declares a key for them. Tables
    /// without one are read-only, and the match-every-column fallback is never used.
    case keyed(MutationKinds)

    /// Any row in a result may be identified, falling back to matching every selected
    /// column where the catalog declares no key. Only for engines where that filter is
    /// cheap and the tables are small enough for it to be honest — SQLite, CSV, and a
    /// local Postgres.
    case unrestricted(MutationKinds)

    /// The mutations permitted, empty when none are.
    public var kinds: MutationKinds {
        switch self {
        case .readOnly: []
        case .keyed(let kinds), .unrestricted(let kinds): kinds
        }
    }

    /// Whether a row with no declared key may still be mutated by matching every
    /// column. False is the safe answer and the default for anything new.
    public var allowsKeylessRows: Bool {
        if case .unrestricted = self { true } else { false }
    }

    public func permits(_ kind: MutationKinds) -> Bool {
        kinds.contains(kind)
    }

}

public struct MutationKinds: OptionSet, Sendable, Hashable {

    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let update = MutationKinds(rawValue: 1 << 0)
    public static let insert = MutationKinds(rawValue: 1 << 1)
    public static let delete = MutationKinds(rawValue: 1 << 2)
    public static let dropTable = MutationKinds(rawValue: 1 << 3)

    public static let rowEdits: MutationKinds = [.update, .insert, .delete]
    public static let all: MutationKinds = [.update, .insert, .delete, .dropTable]

}

// MARK: - Schema

/// Whether a result has columns.
///
/// `.documents` is what makes a document store expressible without giving up the
/// rectangular row storage everything downstream is built on. A document result is
/// still rectangular — it has exactly one column, whose shape is ``DataShape/variant``
/// and whose cells are the documents. The grid then offers a projection built by
/// sampling the first page, so the common case still looks like a table, and the
/// underlying result never has to be a ragged array of dictionaries.
public enum SchemaModel: Sendable, Equatable {

    /// Fixed columns, known before the first row, every row the same width.
    case rectangular

    /// One self-describing value per row. Columns are a view the app derives, not
    /// something the engine reported.
    case documents

}

// MARK: - Scripting

public enum ScriptingSupport: Sendable, Equatable {

    /// One statement per request. The app splits a script and runs the statements in
    /// order, which is also the only way to attribute an error to the statement that
    /// caused it — a REST engine reports a failure for the request, not for a
    /// character offset within it.
    case singleStatement

    /// The driver accepts `a; b; c` and reports the last statement's result. What
    /// libpq and DuckDB do.
    case script

}

// MARK: - Transactions

/// Whether a request can be made all-or-nothing, and who has to arrange it.
///
/// The distinction the middle case draws is the reason this is not a `Bool`. Postgres
/// already runs a whole simple-query message as one implicit transaction, and a driver
/// that "helpfully" added its own `BEGIN` would make that *worse*, not better: a script
/// that fails halfway never reaches its `COMMIT`, so the connection goes back to the
/// pool inside an aborted transaction and poisons whoever borrows it next. Knowing that
/// the engine has already done it is what stops the app doing it again.
///
/// `.none` is the default and the safe answer for anything new. It is not a small
/// admission — a connection that cannot group statements cannot apply a set of edits
/// without the possibility of half of them landing — so ``Session/validate(_:)`` refuses
/// an atomic request outright rather than running it as a plain script and letting the
/// caller believe it was protected.
public enum TransactionSupport: Sendable, Equatable {

    /// Statements land one at a time and nothing groups them. An engine with no
    /// transactions at all, or one whose driver has no way to express them.
    case none

    /// A request is *already* a transaction: the engine commits it whole or not at all,
    /// however many statements it holds. Postgres over the simple query protocol.
    case implicitPerRequest

    /// The engine has transactions but will not start one on its own — the driver must
    /// send `BEGIN` and `COMMIT` itself, and `ROLLBACK` when the body fails. MySQL,
    /// SQLite, DuckDB.
    case explicit

    /// Whether an atomic request can be honoured at all.
    public var isSupported: Bool { self != .none }

}

// MARK: - Cancellation

/// How a running query is called off.
///
/// The distinction is not cosmetic. `.none` means Swift task cancellation abandons the
/// *result* while the server keeps working and keeps billing — so the UI must not
/// claim the query was cancelled, only that it stopped waiting. `.token` means
/// cancellation is a separate request that needs no access to the original connection,
/// which is the only shape that works when there is no connection to begin with.
public enum CancellationSupport: Sendable, Equatable {

    /// Nothing can be sent. Abandoning is the best available, and it is not the same
    /// thing as cancelling.
    case none

    /// A side-channel request on the same connection — `PQcancel`, `mysql_kill`.
    case connection

    /// A separate request keyed by a server-assigned id: `jobs.cancel`,
    /// `SYSTEM$CANCEL_QUERY`, `KILL QUERY`.
    case token

}

// MARK: - Pagination

/// Whether the driver delivers a result whole or in windows.
///
/// Distinct from streaming, and conflating the two is the mistake this type exists to
/// prevent. *Streaming* is the driver pushing rows it already has as fast as it reads
/// them, and it is invisible to the caller beyond arriving early. *Pagination* is the
/// caller pulling the next window, which it may choose never to do — that is a
/// decision, it costs a round trip, and against a metered engine it costs money.
///
/// An engine that pages internally (BigQuery's `pageToken`, Snowflake's result chunks)
/// but always drains every page before returning is `.wholeResult`: its paging is the
/// driver's business, not the caller's.
public enum PaginationModel: Sendable, Equatable {

    /// `execute` returns having delivered every row the query will ever produce.
    case wholeResult

    /// `execute` returns a first window and a cursor. Further rows arrive only when
    /// asked for.
    case cursor

}

// MARK: - Cost

/// Whether running a query spends money.
///
/// `.metered` is what earns a query the confirmation step and the dry-run estimate
/// before it. It also disqualifies a connection from every query the app runs on the
/// user's behalf rather than at their request — the reload after an apply, the
/// row-identity probe, ⌘R — none of which the user would knowingly pay for.
public enum CostModel: Sendable, Equatable {

    case free

    /// - Parameter unit: what is billed, for display: "bytes scanned", "credits".
    case metered(unit: String)

    public var isMetered: Bool { self != .free }

}

// MARK: - Identifiers

/// What the engine does with an identifier that was not quoted.
///
/// Needed wherever a name from the catalog meets a name from the user: Snowflake
/// stores `users` as `USERS` and Postgres as `users`, so the same typed word resolves
/// against a different catalog entry in each. Quoting on output is not enough — the
/// comparison happens before anything is rendered.
public enum IdentifierFolding: Sendable, Equatable {

    /// Unquoted identifiers are lowercased. Postgres, Redshift.
    case lower

    /// Unquoted identifiers are uppercased. Snowflake, Oracle.
    case upper

    /// Stored as written. SQLite, MySQL on a case-sensitive filesystem, BigQuery.
    case preserve

    /// Folds `identifier` the way the engine would, for comparison against a catalog
    /// name. Never for rendering into SQL — that is ``SqlDialect``'s job, and it quotes.
    public func folded(_ identifier: String) -> String {
        switch self {
        case .lower: identifier.lowercased()
        case .upper: identifier.uppercased()
        case .preserve: identifier
        }
    }

}

// MARK: - Common shapes

public extension EngineCapabilities {

    /// A local file or server the user owns outright: everything is permitted, and a
    /// keyless table can still be edited because its tables are small enough for the
    /// match-every-column filter to be honest.
    static let localDatabase = EngineCapabilities(
        mutation: .unrestricted(.all),
        scripting: .script,
        transactions: .explicit,
        cancellation: .connection,
        identifierFolding: .lower
    )

    /// A connection whose single table *is* a file — the CSV importers.
    ///
    /// Rows are editable; the table is not droppable, because the driver re-exports it
    /// after every apply and a dropped table leaves the export with nothing to write
    /// back, reporting a failure for changes that already landed.
    ///
    /// Declared here rather than in one driver because two of them serve it — SQLite
    /// and DuckDB both open CSV files, and which one a connection uses is a setting.
    ///
    /// Transactional in the same sense as the database under it, with one edge the
    /// engine cannot cover: the export that writes the table back out is a file write,
    /// and a rollback does not unwrite a file. It is the last thing an apply does, so in
    /// practice it only runs once everything before it has committed — see
    /// `CsvChangesQueryBuilder`.
    static let fileBackedTable = EngineCapabilities(
        mutation: .unrestricted(.rowEdits),
        scripting: .script,
        transactions: .explicit,
        cancellation: .connection,
        identifierFolding: .preserve
    )

    /// A cloud warehouse: rows are read, results arrive in windows, and every query
    /// costs something. The starting point for Snowflake, BigQuery and friends —
    /// narrow it or widen it per engine rather than inventing one from scratch.
    static func warehouse(unit: String) -> EngineCapabilities {
        EngineCapabilities(
            mutation: .readOnly,
            scripting: .singleStatement,
            cancellation: .token,
            pagination: .cursor,
            cost: .metered(unit: unit),
            identifierFolding: .upper
        )
    }

}
