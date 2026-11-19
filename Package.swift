// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "simhost",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SimHostKit", targets: ["SimHostKit"]),
    ],
    targets: [
        .target(
            name: "SimHostKit",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
