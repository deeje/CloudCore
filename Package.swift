// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CloudCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v8)
    ],
    products: [
        .library(name: "CloudCore", targets: ["CloudCore"])
    ],
    targets: [
        .target(name: "CloudCore", path: "CloudCore"),
        .testTarget(name: "CloudCoreTests", dependencies: ["CloudCore"], path: "Tests")
    ]
)
