// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Grove",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "grove-apple-benchmark", targets: ["AppleBenchmark"]),
        .executable(name: "Grove", targets: ["GroveApp"]),
    ],
    targets: [
        .executableTarget(name: "AppleBenchmark"),
        .executableTarget(name: "GroveApp"),
        .testTarget(name: "GroveAppTests", dependencies: ["GroveApp"]),
    ]
)
