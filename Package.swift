// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "simhost",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SimHostKit", targets: ["SimHostKit"]),
        .executable(name: "simhost", targets: ["simhost"]),
    ],
    targets: [
        // The private C functions of Xcode's SimulatorKit, behind a small typed interface.
        .target(name: "CSimHost", linkerSettings: [.linkedFramework("Foundation")]),
        .target(
            name: "SimHostKit",
            dependencies: ["CSimHost"],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .executableTarget(name: "simhost", dependencies: ["SimHostKit"]),
    ]
)
