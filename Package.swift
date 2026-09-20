// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "displaydj",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "display-cli", targets: ["DisplayCLI"]),
        .executable(name: "DisplayDJBar", targets: ["DisplayDJBar"]),
        .executable(name: "displaydj", targets: ["DisplayDJCLI"]),
        .library(name: "VibeDisplayCore", targets: ["VibeDisplayCore"]),
        .library(name: "VibeDisplayServer", targets: ["VibeDisplayServer"]),
        .library(name: "DisplayDJCore", targets: ["DisplayDJCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(name: "DisplayDJCore"),
        .target(name: "VibeDisplayCore", dependencies: ["DisplayDJCore"],
                swiftSettings: [.swiftLanguageMode(.v5)],
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics"), .linkedFramework("AppKit")]),
        .target(name: "VibeDisplayServer", dependencies: ["VibeDisplayCore"],
                swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("Network")]),
        .executableTarget(name: "DisplayCLI", dependencies: ["VibeDisplayCore", "VibeDisplayServer", "DisplayDJCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "DisplayDJCLI", dependencies: ["DisplayDJCore", "VibeDisplayCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .executableTarget(name: "DisplayDJBar", dependencies: ["DisplayDJCore", "VibeDisplayCore"]),
        .testTarget(name: "DisplayDJCoreTests", dependencies: ["DisplayDJCore"]),
        .testTarget(name: "DisplayDJCLITests", dependencies: ["DisplayDJCLI", "DisplayDJCore"]),
        .testTarget(name: "DisplayDJBarTests", dependencies: ["DisplayDJBar"]),
        .testTarget(name: "VibeDisplayCoreTests", dependencies: ["VibeDisplayCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "VibeDisplayServerTests", dependencies: ["VibeDisplayServer"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
