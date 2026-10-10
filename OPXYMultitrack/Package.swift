// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OPXYMultitrack",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "XYKit", targets: ["XYKit"]),
    ],
    targets: [
        // Everything lives in XYKit so the tests can reach it with @testable import.
        .target(name: "XYKit", path: "Sources/XYKit"),
        .executableTarget(name: "OPXYMultitrack", dependencies: ["XYKit"], path: "Sources/OPXYMultitrack"),
        .testTarget(name: "XYKitTests", dependencies: ["XYKit"], path: "Tests/XYKitTests"),
    ]
)
