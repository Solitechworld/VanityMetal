// swift-tools-version:5.7
//
//  VanityMetal — GPU vanity address engine for Apple Silicon & T2 Macs
//  Standalone: no external scripts, no third-party dependencies.
//
import PackageDescription

let package = Package(
    name: "VanityMetal",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "VanityMetal", targets: ["VanityMetalApp"]),
        // A verification run that needs no XCTest, so it works on a plain
        // Command Line Tools install without full Xcode.
        .executable(name: "VanityMetalVerify", targets: ["VanityMetalVerify"]),
        .library(name: "VanityMetalCore", targets: ["VanityMetalCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VanityMetalCore",
            path: "Sources/VanityMetalCore"
        ),
        .executableTarget(
            name: "VanityMetalApp",
            dependencies: ["VanityMetalCore"],
            path: "Sources/VanityMetalApp"
        ),
        .executableTarget(
            name: "VanityMetalVerify",
            dependencies: ["VanityMetalCore"],
            path: "Sources/VanityMetalVerify"
        ),
        // Only built by `swift test`, which needs full Xcode for XCTest.
        .testTarget(
            name: "VanityMetalCoreTests",
            dependencies: ["VanityMetalCore"],
            path: "Tests/VanityMetalCoreTests"
        )
    ]
)
