// swift-tools-version: 5.9
import Foundation
import PackageDescription

let frameworkLibraryType: Product.Library.LibraryType? =
    ProcessInfo.processInfo.environment["MAPCONDUCTOR_BUILD_XCFRAMEWORK"] == "1" ? .dynamic : nil
let usingLocalCore = FileManager.default.fileExists(atPath: "../ios-sdk-core/Package.swift")
let coreDependency: Package.Dependency = usingLocalCore
    ? .package(path: "../ios-sdk-core")
    : .package(url: "https://github.com/MapConductor/ios-sdk-core", from: "1.0.0")

let package = Package(
    name: "ios-for-here",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "MapConductorForHERE",
            type: frameworkLibraryType,
            targets: ["MapConductorForHERE"]
        ),
    ],
    dependencies: [
        coreDependency,
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
            path: "../heresdk/frameworks/heresdk.xcframework"
        ),
    ]
)
