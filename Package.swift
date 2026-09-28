// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Daisy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Daisy", targets: ["DaisyApp"]),
        .executable(name: "daisy-check", targets: ["DaisyCheck"]),
        .executable(name: "daisy-contacts", targets: ["DaisyContacts"]),
        .executable(name: "daisy-tests", targets: ["DaisyTests"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "DaisyCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "DaisyApp", dependencies: ["DaisyCore"]),
        .executableTarget(name: "DaisyCheck", dependencies: ["DaisyCore"]),
        .executableTarget(name: "DaisyContacts", dependencies: ["DaisyCore"]),
        // The standalone test runner works with Apple's Command Line Tools (no full Xcode/XCTest required).
        .executableTarget(name: "DaisyTests", dependencies: ["DaisyCore"], path: "Tests/DaisyCoreTests")
    ]
)
