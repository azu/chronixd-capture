// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "chronixd-capture",
    platforms: [.macOS("26")],
    products: [
        .executable(name: "chronixd-capture-cli", targets: ["yap"]),
        .executable(name: "chronixd-capture", targets: ["chronixd-capture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/tuist/Noora.git", from: "0.40.1"),
    ],
    targets: [
        .executableTarget(
            name: "yap",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Noora", package: "Noora"),
            ]
        ),
        .executableTarget(
            name: "chronixd-capture",
            dependencies: []
        ),
    ]
)
