// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ios-for-here",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "MapConductorForHERE",
            targets: ["MapConductorForHERE"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MapConductor/ios-sdk-core", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MapConductorForHERE",
            dependencies: [
                .product(name: "MapConductorCore", package: "ios-sdk-core"),
                "heresdk",
            ]
        ),
        .binaryTarget(
            name: "heresdk",
            path: "../../../heresdk/frameworks/heresdk.xcframework"
        ),
    ]
)
