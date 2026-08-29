// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AtollPluginManager",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AtollPluginManager", targets: ["AtollPluginManager"])
    ],
    dependencies: [
        .package(path: "../AtollExtensionKit")
    ],
    targets: [
        .executableTarget(
            name: "AtollPluginManager",
            dependencies: [
                .product(name: "AtollExtensionKit", package: "AtollExtensionKit")
            ],
            path: "Sources/AtollPluginManager"
        ),
        .testTarget(
            name: "AtollPluginManagerTests",
            dependencies: ["AtollPluginManager"],
            path: "Tests/AtollPluginManagerTests"
        )
    ]
)
