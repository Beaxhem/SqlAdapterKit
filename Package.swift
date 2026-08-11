// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SqlAdapterKit",
    platforms: [.macOS(.v14)],
    products: [
        // The engine API every driver is built on, row storage included.
        .library(
            name: "DataEngine",
            targets: ["DataEngine", "ConnectionPool"]),
        // A product so each driver package can run the shared conformance suite
        // against its own session — which is the point of having one.
        .library(
            name: "DataEngineTestKit",
            targets: ["DataEngineTestKit"]),
    ],
    targets: [
        // The row storage — RowStore, RowSegment, FieldArena, StreamingResultBuilder —
        // used to be a target of its own, alongside the `SqlAdapter` protocol that has
        // since been deleted. Splitting them bought nothing once the protocol was gone:
        // nothing depends on the storage without also depending on the engine API, and
        // `ExecutionOutcome` is a pair of them.
        .target(name: "DataEngine"),

        .target(name: "ConnectionPool", dependencies: [.target(name: "DataEngine")]),

        // The conformance suite and the in-memory reference engine. A product of its
        // own so each driver package can run the suite against itself.
        .target(
            name: "DataEngineTestKit",
            dependencies: [.target(name: "DataEngine"), .target(name: "ConnectionPool")]
        ),

        .testTarget(
            name: "DataEngineTests",
            dependencies: [.target(name: "DataEngine"), .target(name: "DataEngineTestKit")]
        ),
    ]
)
