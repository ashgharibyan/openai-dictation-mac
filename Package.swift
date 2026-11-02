// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Dictate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dictate", targets: ["Dictate"]),
    ],
    targets: [
        // Pure Foundation logic: request building, response parsing, text processing,
        // state machine, pricing. No AppKit, so it is unit-testable from the command line.
        .target(name: "DictateCore"),
        // The menu bar app itself.
        .executableTarget(
            name: "Dictate",
            dependencies: ["DictateCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        // XCTest is not available with Command Line Tools only, so the tests are a small
        // self-contained executable: `swift run DictateCoreTests`.
        .executableTarget(name: "DictateCoreTests", dependencies: ["DictateCore"]),
    ]
)
