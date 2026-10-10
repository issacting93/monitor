// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OPXYMonitor",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "./OPXYMultitrack"),
    ],
    targets: [
        .executableTarget(
            name: "MonitorCLI",
            dependencies: [
                .product(name: "XYKit", package: "OPXYMultitrack"),
            ],
            path: "Sources/MonitorCLI"
        ),
        .executableTarget(
            name: "MonitorUI",
            dependencies: [
                .product(name: "XYKit", package: "OPXYMultitrack"),
            ],
            path: "Sources/MonitorUI"
        ),
    ]
)
