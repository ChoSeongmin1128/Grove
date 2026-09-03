// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MossHarness",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", exact: "0.1.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
    ],
    targets: [
        .executableTarget(name: "MossHarness", dependencies: [
            .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            .product(name: "MLX", package: "mlx-swift"),
        ]),
    ]
)
