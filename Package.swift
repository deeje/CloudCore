// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CloudCore",
    defaultLocalization: "en",
    platforms: [
        // Oldest targeted platform versions that are supported by this product.
        .macOS(.v11),
        .iOS(.v13),
        .tvOS(.v12),
        .watchOS(.v6)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "CloudCore",
            targets: ["CloudCore"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "CloudCore",
            dependencies: [],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "CloudCoreTests",
            dependencies: ["CloudCore"],
            resources: [.copy("Resources"), .copy("model.xcdatamodeld")]
        
        ),
        .testTarget(
            name: "CloudKitTests",
            dependencies: ["CloudCore"],
            resources: [.copy("App"),
                        .copy("Resources")
                       
                       ]
        ),
    ]
)
