//
//  ObjectInspectionTests.swift
//  DataEngineTests
//

import Testing
import Foundation
import DataEngine

@Suite("Object inspection schema")
struct ObjectInspectionTests {

    /// The Postgres-shaped declaration, kept here rather than imported so this suite
    /// pins the *type's* behaviour and not one engine's choices.
    private let schema: ObjectInspectionSchema = [
        .table: [.columns, .indexes, .constraints, .storage],
        .view: [.definition, .columns],
        .function: [.signature, .source]
    ]

    @Test("declared order is the order the strip draws")
    func order() {
        #expect(schema.sections(for: .table).map(\.id) == ["columns", "indexes", "constraints", "storage"])

        // Not alphabetised, and that is the point: "Definition" comes first for a view
        // because it is what someone opened the view to read.
        #expect(schema.sections(for: .view).map(\.id) == ["definition", "columns"])
    }

    /// Empty is a real answer, not a missing entry to be papered over: it is what makes
    /// a kind with nothing to say do nothing when clicked, rather than open a pane of
    /// failing panels.
    @Test("an undeclared kind has no sections")
    func undeclaredKind() {
        #expect(schema.sections(for: .stage).isEmpty)
        #expect(schema.sections(for: .sequence).isEmpty)
        #expect(ObjectInspectionSchema.none.sections(for: .table).isEmpty)
        #expect(ObjectInspectionSchema.none.isEmpty)
        #expect(!schema.isEmpty)
    }

    /// How a persisted "last section I looked at" survives being carried to another
    /// engine, or to another kind on the same one: it is discarded, not fetched.
    @Test("a section is found only under the kind that declared it")
    func sectionLookup() {
        #expect(schema.section("columns", of: .table)?.title == "Columns")

        // Declared for a table and not for a function, so asking a function for it
        // must not find the table's.
        #expect(schema.section("indexes", of: .function) == nil)
        #expect(schema.section("source", of: .table) == nil)
        #expect(schema.section("nonesuch", of: .table) == nil)
    }

    /// Kinds are keyed by id, so a lookup cannot miss because the sidebar's declaration
    /// of `.table` and this one differ in a field neither of them is about.
    @Test("kinds match on id, not on every field")
    func kindIdentity() {
        let relabelled = CatalogObjectKind(id: "table", level: .database, isQueryable: false)

        #expect(schema.sections(for: relabelled).map(\.id) == schema.sections(for: .table).map(\.id))
        #expect(schema.sections(forKind: "table").count == 4)
    }

    /// The pairing between what a section declares and what a provider answers with.
    /// Unchecked, a provider returning the wrong shape draws an empty panel and looks
    /// like a query that found nothing.
    @Test("content is checked against the form its section declared")
    func contentForm() {
        #expect(ObjectSectionContent.source("SELECT 1").form == .source)
        #expect(ObjectSectionContent.properties([]).form == .properties)

        #expect(ObjectSectionContent.source("SELECT 1").matches(.definition))
        #expect(!ObjectSectionContent.source("SELECT 1").matches(.columns))
        #expect(ObjectSectionContent.properties([]).matches(.storage))
        #expect(!ObjectSectionContent.properties([]).matches(.source))
    }

    /// nil is not "": a sequence that has never been used reports no last value, and a
    /// role without privileges on it reports none either. Both are absences the
    /// renderer draws, and neither is a zero.
    @Test("a property distinguishes no answer from an empty one")
    func propertyAbsence() {
        #expect(ObjectProperty(name: "Last value", value: nil).value == nil)
        #expect(ObjectProperty(name: "Owner", value: "").value == "")

        // Identity is the name, which is unique within a section.
        #expect(ObjectProperty(name: "Owner", value: "a").id == "Owner")
    }

}
