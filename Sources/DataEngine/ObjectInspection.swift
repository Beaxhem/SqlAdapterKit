//
//  ObjectInspection.swift
//  DataEngine
//

import Foundation

/// One panel of what an object has to say about itself — a table's columns, a
/// function's source, a sequence's parameters.
///
/// Exists because the alternative is a view per ``CatalogObjectKind``, which is ten
/// views today and one more per kind an engine learns to list. Every object any of
/// these engines can describe answers in one of three shapes (see ``Form``), so a kind
/// differs from another kind only in *which sections it declares* — not in how any of
/// them is drawn.
///
/// Declared per engine on ``EngineDescriptor/inspection``, for the same reason
/// ``CatalogShape/leafKinds`` is: what an engine can answer varies, and it varies in
/// ways no shared list could paper over. Postgres has `pg_get_functiondef` and no
/// `SHOW CREATE TABLE` at all; MySQL is the other way round. An engine declares what it
/// can fill and nothing else, so a section that is on screen is a section that will
/// answer.
public struct ObjectSection: Sendable, Hashable, Identifiable {

    /// Which of the three renderers draws this section.
    ///
    /// Not a hint — it is the whole of what the UI needs to know about a section it has
    /// never heard of. An engine adding "Partitions" adds a declaration and a query, and
    /// nothing downstream changes, because the form says it is a grid and grids are
    /// already drawn.
    public enum Form: Sendable, Hashable {

        /// Rows, drawn by the same grid a query result gets — read-only, unattributed,
        /// with no row identity behind it.
        case grid

        /// One blob of SQL or code, syntax-coloured and read-only.
        case source

        /// A list of name/value facts.
        case properties

    }

    /// How a `.source` section's text gets back into the database, for the engines and
    /// kinds where it can.
    ///
    /// Two cases because the catalogs answer in two shapes, and the difference is not
    /// cosmetic. `pg_get_functiondef` hands back a complete `CREATE OR REPLACE FUNCTION`
    /// — what is on screen is exactly what has to be run. `pg_get_viewdef` hands back the
    /// `SELECT` and nothing else, so replacing a view means building the statement back
    /// around what the user edited.
    ///
    /// Rendering is the query builder's job, not this type's: it is the thing that holds
    /// the dialect, and quoting an identifier here would mean a second opinion about it.
    public enum SourceEdit: Sendable, Hashable {

        /// The panel holds a complete statement the engine will accept back unchanged.
        case statement

        /// The panel holds what follows `AS`, and applying it wraps the text in
        /// `CREATE OR REPLACE VIEW`.
        case replacingView

    }

    /// Stable across releases: this is persisted as the section a kind was last opened
    /// on, so renaming one silently sends the user back to the first section.
    public let id: String

    /// What the section strip calls it.
    public let title: String

    public let form: Form

    /// Non-nil where this panel may be edited and written back. nil — the default, and
    /// the answer for every section but a handful — means read-only.
    ///
    /// Declared per engine *and* per kind rather than on the shared section constants,
    /// because that is the granularity the answer actually has. Postgres can replace a
    /// view's ``definition`` and cannot replace a materialized view's, which is the same
    /// section id, the same query behind it and two different answers; MySQL's
    /// `SHOW CREATE VIEW` is a third. So `.definition` itself carries no permission and
    /// the engine's ``ObjectInspectionSchema`` grants it — see `AppEngines`.
    public let editing: SourceEdit?

    public init(id: String, title: String, form: Form, editing: SourceEdit? = nil) {
        self.id = id
        self.title = title
        self.form = form
        self.editing = editing
    }

}

public extension ObjectSection {

    /// This section, with editing granted. What an engine writes in its `inspection`
    /// declaration: `.definition.editable(as: .replacingView)`.
    ///
    /// Refuses on any form but ``Form/source``. A grid of columns and a list of
    /// properties are *readings* of a catalog rather than text an engine will take back,
    /// and granting one editing would put an editor over rows there is no statement to
    /// write them with.
    func editable(as edit: SourceEdit) -> ObjectSection {
        guard form == .source else {
            assertionFailure("Only a .source section can be edited — \(id) is \(form).")
            return self
        }

        return ObjectSection(id: id, title: title, form: form, editing: edit)
    }

}

// MARK: - The sections engines actually declare

public extension ObjectSection {

    /// Name, type, nullability, default. The one section nearly every kind of relation
    /// has, and the one people open the inspector for.
    static let columns = ObjectSection(id: "columns", title: "Columns", form: .grid)

    static let indexes = ObjectSection(id: "indexes", title: "Indexes", form: .grid)

    /// Keys, checks and foreign keys. Separate from ``indexes`` because they are
    /// separate catalogs — a unique constraint and the index enforcing it are one thing
    /// to the user and two rows to the engine, and merging them here would mean
    /// deciding which to hide.
    static let constraints = ObjectSection(id: "constraints", title: "Constraints", form: .grid)

    /// Size on disk, row estimates, when it was last vacuumed. Properties rather than a
    /// grid: there are six of them and they are facts about one object, not a list.
    static let storage = ObjectSection(id: "storage", title: "Storage", form: .properties)

    /// What a view selects — the statement the engine stores, not a reconstruction.
    static let definition = ObjectSection(id: "definition", title: "Definition", form: .source)

    /// The statement that would recreate this object, as the **engine itself** renders it
    /// — `SHOW CREATE TABLE`, `sqlite_master.sql`, ClickHouse's `SHOW CREATE`.
    ///
    /// Distinct from ``definition``, which is a view's `SELECT`: this is the whole object
    /// including its keys, its indexes and its engine options. Declared only by engines
    /// that actually store one — Postgres does not, and `pg_dump` assembling it
    /// client-side is not something a browser reimplements.
    ///
    /// Read-only everywhere, deliberately. Editing it would mean a `DROP` and a `CREATE`,
    /// which is not a change this app queues — see ``SourceEdit``, whose two cases are
    /// both replacements of something that can be replaced in place.
    static let ddl = ObjectSection(id: "ddl", title: "DDL", form: .source)

    /// Arguments, return type, language, volatility. What you need to *call* the thing,
    /// as opposed to ``source``, which is what it does.
    static let signature = ObjectSection(id: "signature", title: "Signature", form: .properties)

    /// A routine's body, as the engine stores it.
    static let source = ObjectSection(id: "source", title: "Source", form: .source)

    /// For a kind whose whole description is a handful of facts — a sequence's bounds
    /// and increment, a stream's mode. Generic on purpose: an object with one section
    /// does not need it named twice.
    static let properties = ObjectSection(id: "properties", title: "Properties", form: .properties)

}

// MARK: - Schema

/// Which sections each kind of object offers, for one engine.
///
/// Static data, known before a connection exists — which is the point. The section
/// strip, the tab title and the selected section can all be drawn on the first frame
/// with no query in flight, so an inspector opens looking complete and fills in one
/// panel. Deriving this from a fetch instead would mean opening onto an empty frame and
/// growing the chrome underneath the user.
///
/// **Read this off the engine's descriptor, never off a provider's snapshot.**
/// `Metadata.shape` is the *provider's* shape and every provider still writes a literal,
/// so a lookup routed through one gets the mock's answer under test and nothing at all
/// in the app — the exact two-source-of-truth gap that hid the kind funnel for a day.
/// `Host` resolves both the catalog shape and this from `engine.descriptor`.
public struct ObjectInspectionSchema: Sendable, ExpressibleByDictionaryLiteral {

    /// Keyed by ``CatalogObjectKind/id`` rather than by the kind, so a lookup cannot
    /// miss because two declarations of `.table` differ in a field the sidebar set and
    /// this one did not.
    private let sectionsByKind: [CatalogObjectKind.ID: [ObjectSection]]

    public init(dictionaryLiteral elements: (CatalogObjectKind, [ObjectSection])...) {
        self.sectionsByKind = Dictionary(
            elements.map { ($0.id, $1) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// What `kind` has to say about itself here, empty for a kind this engine cannot
    /// describe.
    ///
    /// Empty is a real answer and the UI must honour it: it is what makes clicking a
    /// stage on an engine with no `LIST` do nothing rather than open a pane of four
    /// failing panels.
    public func sections(for kind: CatalogObjectKind) -> [ObjectSection] {
        sectionsByKind[kind.id] ?? []
    }

    public func sections(forKind id: CatalogObjectKind.ID) -> [ObjectSection] {
        sectionsByKind[id] ?? []
    }

    /// The section with this id among `kind`'s, or nil for one this engine never
    /// declared — how a persisted "last section I looked at" from another engine is
    /// discarded rather than fetched.
    public func section(_ id: ObjectSection.ID, of kind: CatalogObjectKind) -> ObjectSection? {
        sections(for: kind).first { $0.id == id }
    }

    /// Whether anything at all can be inspected here. False for an engine that has not
    /// declared a single kind, which is every engine until its provider can fill one.
    public var isEmpty: Bool { sectionsByKind.isEmpty }

    /// The kinds this engine describes.
    ///
    /// Exposed for the agreement test rather than for the UI, which always asks about
    /// the one kind it is holding. What it catches is a declaration for a kind the
    /// engine's ``CatalogShape`` does not list — sections nothing can ever open, which
    /// is invisible until someone goes looking for the panel they wrote.
    public var declaredKinds: Set<CatalogObjectKind.ID> { Set(sectionsByKind.keys) }

    /// An engine that describes nothing. The default, so adding this to
    /// ``EngineDescriptor`` costs the engines that have not been taught it nothing.
    public static let none = ObjectInspectionSchema()

}

// MARK: - Content

/// What a filled section holds.
///
/// One case per ``ObjectSection/Form``, and they are paired: a `.grid` section is
/// answered with ``rows`` and nothing else. ``form`` exists so that pairing can be
/// checked rather than assumed — a provider answering a declared `.source` section with
/// properties is a bug that should surface as a failed section, not as an empty panel.
public enum ObjectSectionContent: Sendable {

    /// Carried as a whole ``ExecutionOutcome`` so the existing result pipeline serves
    /// this unchanged — columns, widths, search and copy all come for free. Read-only
    /// downstream: there is no table behind these rows to attribute an edit to.
    case rows(ExecutionOutcome)

    case source(String)

    case properties([ObjectProperty])

    /// The form this content can be drawn as.
    public var form: ObjectSection.Form {
        switch self {
        case .rows: .grid
        case .source: .source
        case .properties: .properties
        }
    }

    /// Whether this is what `section` declared it would be. Checked where content is
    /// installed, and asserted across every declared section by the conformance suite —
    /// which is the only place the check catches a *provider* rather than a caller.
    public func matches(_ section: ObjectSection) -> Bool {
        form == section.form
    }

}

/// One fact about an object.
///
/// `value` is optional because "no answer" is a real one and is not the same as an
/// empty string: a sequence that has never been used reports no `last_value`, and a
/// role without privileges on it reports none either. The renderer draws the absence;
/// inventing a zero here would make an unused sequence look like a spent one.
public struct ObjectProperty: Sendable, Hashable, Identifiable {

    /// The name, which is unique within a section and is therefore the identity.
    public var id: String { name }

    public let name: String

    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }

}
