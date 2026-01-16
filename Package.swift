// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Organize",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "OrganizeCore",
            targets: ["OrganizeCore"]
        ),
        .executable(
            name: "organize",
            targets: ["OrganizeCLI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0")
    ],
    targets: [
        .target(
            name: "OrganizeCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/OrganizeCore"
        ),
        .executableTarget(
            name: "OrganizeCLI",
            dependencies: [
                "OrganizeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/OrganizeCLI"
        ),
        .testTarget(
            name: "OrganizeCoreTests",
            dependencies: ["OrganizeCore"],
            path: "Tests/OrganizeCoreTests"
        )
    ]
)
