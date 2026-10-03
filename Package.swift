// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Inttegro",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "Inttegro", targets: ["Inttegro"]),
        .library(name: "InttegroBridge", targets: ["InttegroBridge"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin",
            exact: "1.5.0"
        ),
    ],
    targets: [
        .target(
            name: "Inttegro",
            resources: [.process("Resources")]
        ),
        .target(
            name: "InttegroBridge",
            dependencies: ["Inttegro"]
        ),
        .testTarget(
            name: "InttegroTests",
            dependencies: ["Inttegro", "InttegroBridge"]
        ),
    ]
)
