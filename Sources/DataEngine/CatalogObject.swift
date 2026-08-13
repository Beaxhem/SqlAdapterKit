//
//  CatalogObject.swift
//  DataEngine
//

import Foundation

/// A class of thing that lives at the leaf of a catalog — a table, a view, a stored
/// function.
///
/// Exists so "what the sidebar shows" is a value the user can change rather than a
/// decision each provider makes for itself. It is made for itself today, and made
/// differently: Postgres filters `table_type = 'BASE TABLE'` so its views are invisible,
/// while Snowflake merges tables and views deliberately. Neither is wrong on its own and
/// together they are indefensible, because the sidebar means something different
/// depending on which connection you are looking at.
///
/// Declared per engine on ``CatalogShape/leafKinds``, so a kind no engine can list is a
/// kind the UI never offers. That is the same arrangement ``EngineCapabilities`` has with
/// the grid, and for the same reason — the alternative is a menu that lists "Stages" for
/// SQLite and reports an error when it is ticked.
public struct CatalogObjectKind: Sendable, Hashable, Identifiable {

    /// Stable across releases: this is persisted as part of a connection's visible-kind
    /// set, so renaming one silently resets whatever the user had chosen.
    public let id: String

    /// What to call a row of this kind and what to draw beside it. Reuses
    /// ``CatalogLevel`` because the questions are identical — singular, plural, icon —
    /// and a second type answering them would be one more thing to keep in step.
    public let level: CatalogLevel

    /// Whether a connection that has never been configured shows this kind.
    ///
    /// True for the things you can `SELECT` from and false for everything else. The
    /// point of the switch is that a sidebar opens showing what someone came for; a
    /// default that shows every sequence and every stored procedure is the tree this
    /// feature exists to avoid, just without the indentation.
    public let isDefaultVisible: Bool

    /// Whether `SELECT * FROM` it means anything.
    ///
    /// Load-bearing the moment the sidebar holds more than tables, in three places that
    /// would each be wrong in their own way without it: clicking a row opens a grid,
    /// dragging one drops `SELECT * FROM` into an editor, and a `TableRef` is what a
    /// generated `UPDATE` names. A stored procedure is none of those things, and the
    /// alternative to asking here is three separate lists of which kinds are exempt.
    public let isQueryable: Bool

    public init(
        id: String,
        level: CatalogLevel,
        isDefaultVisible: Bool = false,
        isQueryable: Bool = false
    ) {
        self.id = id
        self.level = level
        self.isDefaultVisible = isDefaultVisible
        self.isQueryable = isQueryable
    }

}

// MARK: - The kinds engines actually report

public extension CatalogObjectKind {

    /// The only kind anything may be written back to. Every other queryable kind is
    /// readable and not writable, which ``EngineCapabilities/mutation`` cannot express
    /// because it is declared per connection and this is per object.
    static let table = CatalogObjectKind(
        id: "table",
        level: .table,
        isDefaultVisible: true,
        isQueryable: true
    )

    static let view = CatalogObjectKind(
        id: "view",
        level: .init(singular: "View", plural: "Views", icon: "eye"),
        isDefaultVisible: true,
        isQueryable: true
    )

    /// Visible by default alongside plain views: it is a view, and the storage behind it
    /// is an implementation detail of the engine rather than a reason to hide it.
    static let materializedView = CatalogObjectKind(
        id: "materializedView",
        level: .init(
            singular: "Materialized view",
            plural: "Materialized views",
            icon: "rectangle.on.rectangle"
        ),
        isDefaultVisible: true,
        isQueryable: true
    )

    static let function = CatalogObjectKind(
        id: "function",
        level: .init(singular: "Function", plural: "Functions", icon: "function")
    )

    static let procedure = CatalogObjectKind(
        id: "procedure",
        level: .init(singular: "Procedure", plural: "Procedures", icon: "gearshape")
    )

    static let sequence = CatalogObjectKind(
        id: "sequence",
        level: .init(singular: "Sequence", plural: "Sequences", icon: "number")
    )

    /// Snowflake's file staging areas.
    static let stage = CatalogObjectKind(
        id: "stage",
        level: .init(singular: "Stage", plural: "Stages", icon: "shippingbox")
    )

    /// Queryable: a Snowflake stream is selected from exactly like a table — it is the
    /// change log of one.
    static let stream = CatalogObjectKind(
        id: "stream",
        level: .init(singular: "Stream", plural: "Streams", icon: "waveform"),
        isQueryable: true
    )

    static let task = CatalogObjectKind(
        id: "task",
        level: .init(singular: "Task", plural: "Tasks", icon: "clock.arrow.circlepath")
    )

    /// ClickHouse's dictionaries, which are queryable but are not tables.
    static let dictionary = CatalogObjectKind(
        id: "dictionary",
        level: .init(
            singular: "Dictionary",
            plural: "Dictionaries",
            icon: "character.book.closed"
        ),
        isQueryable: true
    )

}

// MARK: - Sets of kinds

/// On the array rather than on the element, so a shape reads `.listing(.relations)`
/// where it expects a list.
public extension Array where Element == CatalogObjectKind {

    /// The things you can `SELECT` from, which every engine here can list.
    static var relations: [CatalogObjectKind] { [.table, .view] }

}
