//
//  ColumnDescriptor.swift
//  DataEngine
//

import Foundation

// MARK: - Names

/// A qualified name, however many parts the engine's catalog has.
///
/// One type for `users`, `public.users` and `my-project.analytics.events`. The count
/// is data rather than structure, which is what stops a third level from being a
/// change to every type that mentions a table — the two-part assumption is currently
/// baked into `TableRef.queryName`, and BigQuery and Snowflake both have three.
public struct CatalogPath: Sendable, Hashable {

    public let components: [String]

    public init(_ components: [String]) {
        self.components = components
    }

    public init(_ components: String...) {
        self.init(components)
    }

    /// The object's own name, unqualified — what the sidebar shows.
    public var leaf: String { components.last ?? "" }

    /// Everything above the leaf, or nil at the root.
    public var parent: CatalogPath? {
        components.count > 1 ? CatalogPath(components.dropLast()) : nil
    }

    public var isEmpty: Bool { components.isEmpty }

    public func appending(_ component: String) -> CatalogPath {
        CatalogPath(components + [component])
    }

    /// Qualified and quoted, ready to interpolate into a statement. Rendering is the
    /// dialect's business — this only decides where the separators go.
    public func rendered(quoting quote: (String) -> String, separator: String = ".") -> String {
        components.map(quote).joined(separator: separator)
    }

}

extension CatalogPath: CustomStringConvertible {

    public var description: String { components.joined(separator: ".") }

}

/// Catalog identity for an object a column can be selected from.
///
/// Generalizes what `TableKey` did for two engines. Postgres hands back an oid, which
/// carries no name and is only ever resolvable through the catalog; everyone else
/// names the thing, which can be resolved without one — which is what lets the
/// name-based drivers attribute columns before the first catalog load lands.
public enum ObjectKey: Sendable, Hashable {

    /// An engine-assigned identifier — a `pg_class` oid.
    case handle(UInt64)

    /// A qualified name.
    case path(CatalogPath)

}

// MARK: - Shapes

/// A value that is not made of other values.
public enum ScalarKind: Sendable, Hashable {

    case integer
    case decimal
    case float
    case boolean

    case text
    case char

    case date
    case time
    case timestamp
    case timestampWithZone
    case interval

    case binary
    case uuid
    case enumeration
    case geography

    /// The engine named a type this layer has no reading of. Rendered as text, never
    /// edited with anything but a plain field.
    case opaque

    /// Whether values of this kind sort and align as numbers.
    public var isNumeric: Bool {
        switch self {
        case .integer, .decimal, .float: true
        default: false
        }
    }

}

/// What one column holds, to whatever depth the engine describes.
///
/// The recursive cases are what BigQuery's `STRUCT`/`ARRAY`, Snowflake's `VARIANT`
/// and any JSON column need, and describing them costs nothing at read time — see
/// ``CellEncoding``.
public indirect enum DataShape: Sendable, Hashable {

    case scalar(ScalarKind)

    /// A repeated value. BigQuery's `ARRAY<T>`, Postgres' `int[]`.
    case list(DataShape)

    /// A fixed set of named fields. BigQuery's `STRUCT`, Postgres' composite types.
    case record([RecordField])

    /// Keys to values, where the key set is not fixed.
    case map(key: ScalarKind, value: DataShape)

    /// Self-describing and not statically known: Snowflake `VARIANT`, a `JSONB`
    /// column, a document store's row. The members are whatever the value says they
    /// are, discovered when it is decoded rather than declared.
    case variant

    case unknown

    /// Whether a value of this shape contains other values, and therefore wants the
    /// inspector rather than a text field.
    public var isComposite: Bool {
        switch self {
        case .scalar, .unknown: false
        case .list, .record, .map, .variant: true
        }
    }

    /// The scalar this shape is, where it is one.
    public var scalarKind: ScalarKind? {
        if case .scalar(let kind) = self { kind } else { nil }
    }

}

public struct RecordField: Sendable, Hashable {

    public let name: String

    public let shape: DataShape

    public init(name: String, shape: DataShape) {
        self.name = name
        self.shape = shape
    }

}

// MARK: - Encoding

/// How to read the bytes of every cell in one column.
///
/// **On the column, never on the cell.** This is the decision that makes nested data
/// free: a per-cell tag would add a byte and a branch to a path that runs once per
/// cell — six million times for the results `docs/grid-invariants.md` §F measures —
/// to answer a question that cannot vary within a column. Drivers write nested values
/// through the same `appendValue(_:length:)` they write text through, and nothing on
/// the row path knows the difference.
///
/// Decoding happens when a cell is expanded, and only then. A grid showing ten
/// thousand JSON cells parses none of them.
public enum CellEncoding: Sendable, Hashable {

    /// UTF-8, display-ready as it stands. Every scalar.
    case text

    /// UTF-8 JSON. Every composite shape, whatever the engine called it.
    case json

    /// Not text at all — a `BYTEA`, a blob. Rendered as a size and a hex preview.
    case binary

    /// The encoding a value of `shape` arrives in.
    public static func `for`(_ shape: DataShape) -> CellEncoding {
        switch shape {
        case .scalar(.binary): .binary
        case .scalar, .unknown: .text
        case .list, .record, .map, .variant: .json
        }
    }

}

// MARK: - Columns

/// One column of one result.
///
/// A concrete struct, where this used to be `any Column`. The protocol bought nothing
/// — every driver's conformer held the same four fields — and cost an existential on
/// a path the grid walks per column per reload, with a witness-table lookup behind
/// each access. Drivers now build values.
public struct ColumnDescriptor: Sendable, Hashable, Identifiable {

    /// Position in the result. Also the column's identity: results are rectangular,
    /// so a column *is* its index, exactly as a row is its index (`grid-invariants`
    /// rule A5).
    public let id: Int

    public let name: String

    /// The engine's own spelling of the type — `int8`, `NUMBER(38,0)`, `Nullable(String)`.
    /// Shown to the user and used to look up enum members; never parsed.
    public let typeName: String

    public let shape: DataShape

    public let encoding: CellEncoding

    /// The object this column is selected from, or nil when it has no single backing
    /// one — an expression, a literal, or a driver that cannot attribute columns for
    /// the query at hand. A nil origin is what makes a column read-only downstream.
    public let origin: ObjectKey?

    /// Whether the engine says the column admits NULL. `nil` where it does not say,
    /// which is not the same as `true` and must not be shown as a guarantee.
    public let isNullable: Bool?

    public init(
        id: Int,
        name: String,
        typeName: String,
        shape: DataShape,
        encoding: CellEncoding? = nil,
        origin: ObjectKey? = nil,
        isNullable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.typeName = typeName
        self.shape = shape
        self.encoding = encoding ?? .for(shape)
        self.origin = origin
        self.isNullable = isNullable
    }

}

public extension ColumnDescriptor {

    /// The common case: a scalar column whose type name the engine supplied.
    static func scalar(
        id: Int,
        name: String,
        typeName: String,
        kind: ScalarKind,
        origin: ObjectKey? = nil,
        isNullable: Bool? = nil
    ) -> ColumnDescriptor {
        ColumnDescriptor(
            id: id,
            name: name,
            typeName: typeName,
            shape: .scalar(kind),
            origin: origin,
            isNullable: isNullable
        )
    }

    /// Whether this column's cells want the tree inspector rather than a text field.
    var isComposite: Bool { shape.isComposite }

}
