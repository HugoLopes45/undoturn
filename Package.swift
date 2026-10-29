// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "undoturn",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "UndoTurnCore", targets: ["UndoTurnCore"]),
    .executable(name: "undoturn", targets: ["undoturn"]),
    .executable(name: "undoturn-bench", targets: ["undoturn-bench"]),
    .executable(name: "UndoTurnApp", targets: ["UndoTurnApp"]),
    .executable(name: "undoturn-service", targets: ["undoturn-service"]),
  ],
  targets: [
    .target(name: "UndoTurnCore"),
    .executableTarget(
      name: "undoturn",
      dependencies: ["UndoTurnCore"],
      // SwiftPM links Foundation by default. Dropping unused dylibs keeps each hook start small.
      linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip_dylibs"])]
    ),
    .target(name: "UndoTurnLedger", dependencies: ["UndoTurnCore"]),
    .executableTarget(name: "UndoTurnApp", dependencies: ["UndoTurnCore", "UndoTurnLedger"]),
    .executableTarget(name: "undoturn-bench", dependencies: ["UndoTurnCore"]),
    .executableTarget(
      name: "undoturn-service",
      dependencies: ["UndoTurnCore"],
      path: "Sources/UndoTurnService",
      linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip_dylibs"])]
    ),
    .testTarget(name: "UndoTurnCoreTests", dependencies: ["UndoTurnCore"], exclude: ["Fixtures"]),
    .testTarget(name: "UndoTurnCLITests", dependencies: ["undoturn"]),
    .testTarget(name: "UndoTurnLedgerTests", dependencies: ["UndoTurnLedger"]),
    .testTarget(name: "UndoTurnServiceTests", dependencies: ["undoturn-service"]),
  ]
)
