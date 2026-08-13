//
//  CatalogTests.swift
//  DataEngineTests
//

import Testing
import Foundation
import DataEngine

@Suite("Catalog paths and shapes")
struct CatalogTests {

    @Test("a path renders at any depth")
    func rendering() {
        let quote: (String) -> String = { "\"\($0)\"" }

        #expect(CatalogPath("users").rendered(quoting: quote) == "\"users\"")
        #expect(CatalogPath("public", "users").rendered(quoting: quote) == "\"public\".\"users\"")
        #expect(
            CatalogPath("proj", "analytics", "events").rendered(quoting: quote)
                == "\"proj\".\"analytics\".\"events\""
        )
    }

    /// The two-part assumption currently baked into `TableRef.queryName` is what this
    /// replaces, so three parts have to be no more remarkable than two.
    @Test("leaf and parent walk the path")
    func leafAndParent() {
        let path = CatalogPath("proj", "analytics", "events")

        #expect(path.leaf == "events")
        #expect(path.parent == CatalogPath("proj", "analytics"))
        #expect(path.parent?.parent == CatalogPath("proj"))
        #expect(path.parent?.parent?.parent == nil)
        #expect(path.appending("column") == CatalogPath("proj", "analytics", "events", "column"))
    }

    @Test("catalog depth follows the container list")
    func depth() {
        #expect(CatalogShape.flat.depth == 1)
        #expect(CatalogShape.databases.depth == 2)
        #expect(CatalogShape.databaseSchema.depth == 3)
        #expect(CatalogShape.projectDataset.depth == 3)

        #expect(CatalogShape.projectDataset.level(atDepth: 0).singular == "Project")
        #expect(CatalogShape.projectDataset.level(atDepth: 1).singular == "Dataset")
        #expect(CatalogShape.projectDataset.level(atDepth: 2).singular == "Table")
    }

    /// The label every breadcrumb and section header reads still has to come out of a
    /// shape that now holds six kinds rather than one.
    @Test("the leaf label follows the first kind")
    func leafLabel() {
        #expect(CatalogShape.flat.leaf.singular == "Table")
        #expect(CatalogShape.databaseSchema.level(atDepth: 2).plural == "Tables")

        let functionsFirst = CatalogShape.databases.listing([.function, .table])

        #expect(functionsFirst.leaf.singular == "Function")
        #expect(functionsFirst.containers == CatalogShape.databases.containers)
    }

    /// A blank sidebar on a fresh connection is indistinguishable from a broken one, so
    /// the default set is never empty however the kinds were declared.
    @Test("default visibility covers relations and never nothing")
    func defaultVisibleKinds() {
        let postgres = CatalogShape.databases.listing(
            [.table, .view, .materializedView, .function, .procedure, .sequence]
        )

        #expect(postgres.defaultVisibleKinds == ["table", "view", "materializedView"])

        // Every kind opt-in: falls back to the first rather than to none.
        let opaque = CatalogShape.flat.listing([.function, .procedure])

        #expect(opaque.defaultVisibleKinds == ["function"])
    }

    /// What a visible-kind set saved against another engine has to run into: the kind is
    /// not declared here, so it is dropped rather than drawn as an empty row.
    @Test("a kind is only resolvable where the engine declares it")
    func kindLookup() {
        let sqlite = CatalogShape.flat.listing(.relations)

        #expect(sqlite.kind(id: "view") == .view)
        #expect(sqlite.kind(id: "stage") == nil)
    }

    /// Three behaviours hang off this — opening a row, dragging one, and naming one in a
    /// generated statement — so a kind answering it wrongly produces `SELECT * FROM` a
    /// stored procedure.
    @Test("only relations are queryable")
    func queryability() {
        #expect(CatalogObjectKind.table.isQueryable)
        #expect(CatalogObjectKind.view.isQueryable)
        #expect(CatalogObjectKind.materializedView.isQueryable)
        #expect(CatalogObjectKind.stream.isQueryable)
        #expect(CatalogObjectKind.dictionary.isQueryable)

        #expect(!CatalogObjectKind.function.isQueryable)
        #expect(!CatalogObjectKind.procedure.isQueryable)
        #expect(!CatalogObjectKind.sequence.isQueryable)
        #expect(!CatalogObjectKind.stage.isQueryable)
        #expect(!CatalogObjectKind.task.isQueryable)

        // Anything shown by default has to be openable, or a fresh connection lists rows
        // that do nothing when clicked.
        let snowflakeish = CatalogShape.databaseSchema.listing(
            [.table, .view, .materializedView, .function, .stage]
        )

        let shownAtFirst = snowflakeish.leafKinds
            .filter { snowflakeish.defaultVisibleKinds.contains($0.id) }

        #expect(shownAtFirst.count == 3)
        #expect(shownAtFirst.filter(\.isQueryable).count == shownAtFirst.count)
    }

    /// The one rule deciding whether a context field is switchable inline or has to go
    /// through the connection editor.
    @Test("catalog invalidation decides where a context field is edited")
    func sessionContextPlacement() {
        let role = SessionContextField(
            key: "role",
            label: "Role",
            icon: "person.badge.key",
            discovery: .query("SHOW ROLES"),
            invalidatesCatalog: true
        )
        let warehouse = SessionContextField(
            key: "warehouse",
            label: "Warehouse",
            icon: "server.rack",
            discovery: .query("SHOW WAREHOUSES"),
            invalidatesCatalog: false
        )

        #expect(!role.isInlineSwitchable)
        #expect(warehouse.isInlineSwitchable)
        #expect(warehouse.id == SettingKey("warehouse"))
    }

    /// Nested support is free only because encoding is decided by the column's shape.
    /// If this mapping drifts, a driver ends up writing JSON into a column the grid
    /// renders as text.
    @Test("encoding follows shape")
    func encodingFollowsShape() {
        #expect(CellEncoding.for(.scalar(.text)) == .text)
        #expect(CellEncoding.for(.scalar(.integer)) == .text)
        #expect(CellEncoding.for(.scalar(.binary)) == .binary)
        #expect(CellEncoding.for(.variant) == .json)
        #expect(CellEncoding.for(.list(.scalar(.integer))) == .json)
        #expect(CellEncoding.for(.record([.init(name: "a", shape: .scalar(.text))])) == .json)

        #expect(DataShape.scalar(.text).isComposite == false)
        #expect(DataShape.variant.isComposite)
    }

    @Test("mutation support gates the keyless fallback")
    func mutationSupport() {
        #expect(MutationSupport.readOnly.kinds.isEmpty)
        #expect(!MutationSupport.readOnly.allowsKeylessRows)

        #expect(!MutationSupport.keyed(.all).allowsKeylessRows)
        #expect(MutationSupport.keyed(.all).permits(.update))

        #expect(MutationSupport.unrestricted(.all).allowsKeylessRows)
        #expect(!MutationSupport.keyed(.rowEdits).permits(.dropTable))
    }

}
