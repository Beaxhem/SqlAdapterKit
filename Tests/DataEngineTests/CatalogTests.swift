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
