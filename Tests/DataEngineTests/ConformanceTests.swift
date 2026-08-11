//
//  ConformanceTests.swift
//  DataEngineTests
//

import Testing
import Foundation
import DataEngine
import DataEngineTestKit

/// Runs the shared suite over the capability combinations the four new engines will
/// actually present. The point is not that the reference engine works — it is that the
/// *suite* discriminates: a read-only session and a metered one must be held to
/// different rules, and a suite that passed everything regardless would catch nothing
/// when a real driver arrives.
@Suite("Engine conformance")
struct ConformanceTests {

    @Test("a local-database session conforms")
    func localDatabase() async throws {
        try await expectConformance(capabilities: .localDatabase)
    }

    @Test("a read-only, single-statement session conforms")
    func readOnly() async throws {
        try await expectConformance(
            capabilities: EngineCapabilities(mutation: .readOnly, scripting: .singleStatement)
        )
    }

    /// The shape Snowflake and BigQuery will present: read-only, metered, paged, and
    /// cancelled by token.
    @Test("a warehouse-shaped session conforms")
    func warehouse() async throws {
        try await expectConformance(capabilities: .warehouse(unit: "bytes scanned"))
    }

    /// A CSV connection: rows editable, table not droppable, because the table is the
    /// file. The one shipped capability set that is narrower than its driver's.
    @Test("a file-backed table session conforms")
    func fileBackedTable() async throws {
        try await expectConformance(capabilities: .fileBackedTable)
    }

    /// A session that declares a capability it does not honour must fail, or the
    /// declaration is decoration. Guards the suite itself.
    @Test("the suite rejects a session that lies about being read-only")
    func dishonestSessionFails() async throws {
        let session = DishonestSession()

        let report = await EngineConformance.run(session: session, fixture: .reference)

        #expect(!report.didPass)
        #expect(report.failures.contains { $0.name.contains("read-only") })
    }

}

private extension ConformanceTests {

    func expectConformance(capabilities: EngineCapabilities) async throws {
        let engine = ReferenceEngine(capabilities: capabilities)
        let session = try await engine.makeSession(SettingsValues())

        let report = await EngineConformance.run(session: session, fixture: .reference)

        #expect(report.didPass, "\(report.summary)")
    }

}

// MARK: - A session that ignores its own declaration

/// Claims to be read-only and runs writes anyway.
private actor DishonestSession: Session {

    nonisolated let capabilities = EngineCapabilities(mutation: .readOnly)

    func execute(
        _ request: QueryRequest,
        onPartial: (@Sendable (PartialResult) -> Void)?
    ) async throws(QueryError) -> ExecutionOutcome {
        // Deliberately does not call `validate`.
        ExecutionOutcome(
            columns: ReferenceEngine.columns,
            store: .empty,
            statistics: .init(duration: 0)
        )
    }

}
