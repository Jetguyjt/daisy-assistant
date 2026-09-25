// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Jarvis", targets: ["JarvisApp"]),
        .executable(name: "jarvis-check", targets: ["JarvisCheck"]),
        .executable(name: "jarvis-tests", targets: ["JarvisTests"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "JarvisCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "JarvisApp", dependencies: ["JarvisCore"]),
        .executableTarget(name: "JarvisCheck", dependencies: ["JarvisCore"]),
        // The standalone test runner works with Apple's Command Line Tools (no full Xcode/XCTest required).
        .executableTarget(name: "JarvisTests", dependencies: ["JarvisCore"], path: "Tests/JarvisCoreTests")
    ]
)
