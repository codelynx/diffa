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
    ],
    targets: [
        .target(
            name: "Diffalla",
            dependencies: [],
            exclude: [
                "Database/README.md"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS, .iOS, .linux]))
            ]
        ),
        .testTarget(
            name: "DiffallaTests",
            dependencies: ["Diffalla"]
        ),
    ]
)
