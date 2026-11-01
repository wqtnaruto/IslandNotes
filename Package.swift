// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "IslandNotes",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IslandNotes", targets: ["IslandNotes"])
    ],
    targets: [
        .executableTarget(
            name: "IslandNotes",
            path: "Sources/IslandNotes",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "IslandNotesCoreTests",
            dependencies: ["IslandNotes"],
            path: "Tests/IslandNotesCoreTests"
        )
    ]
)
