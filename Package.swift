// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Diffalla",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "Diffalla",
            targets: ["Diffalla"]
        ),
        .executable(
            name: "diffalla-benchmark",
            targets: ["DiffallaBenchmark"]
        ),
    ],
    targets: [
        .target(
            name: "Diffalla",
            dependencies: [],
            exclude: [
                "Database/README.md",
                "Core/README.md",
                "Snapshots/README.md",
                "Comparison/README.md"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS, .iOS, .linux]))
            ]
        ),
        .executableTarget(
            name: "DiffallaBenchmark",
            dependencies: ["Diffalla"],
            path: "Sources/DiffallaBenchmark"
        ),
        .testTarget(
            name: "DiffallaTests",
            dependencies: ["Diffalla"]
        ),
    ]
)
