// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CostSauceKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "CostSauceKit",
            targets: ["CostSauceKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CostSauceKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "CostSauceKitTests",
            dependencies: [
                "CostSauceKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
