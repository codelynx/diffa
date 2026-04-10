// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Diffa",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "Diffa",
            targets: ["Diffa"]
        ),
        .executable(
            name: "diffa",
            targets: ["DiffaCLI"]
        ),
        .executable(
            name: "diffa-benchmark",
            targets: ["DiffaBenchmark"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0")
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            pkgConfig: "zlib",
            providers: [
                .apt(["zlib1g-dev"]),
                .brew(["zlib"])
            ]
        ),
        .target(
            name: "Diffa",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
                "CZlib"
            ],
            path: "Sources/Diffa",
            exclude: [
                "Database/README.md",
                "Core/README.md",
                "Snapshots/README.md",
                "Comparison/README.md",
                "EfficientSync/Core/README.md",
                "EfficientSync/Snapshots/README.md",
                "EfficientSync/Comparison/README.md"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS, .iOS]))
            ]
        ),
        .executableTarget(
            name: "DiffaCLI",
            dependencies: [
                "Diffa",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/DiffaCLI"
        ),
        .executableTarget(
            name: "DiffaBenchmark",
            dependencies: ["Diffa"],
            path: "Sources/DiffaBenchmark"
        ),
        .testTarget(
            name: "DiffaTests",
            dependencies: ["Diffa"],
            path: "Tests/DiffaTests"
        ),
        .testTarget(
            name: "CLIIntegrationTests",
            dependencies: ["Diffa"]
        ),
    ]
)
