// swift-tools-version: 6.1
import Foundation
import PackageDescription

// project-lifecycle builds with PROJECT_LIFECYCLE_PACKAGE set to its own checkout, so the
// shared package comes from disk. A plain `swift build` fetches it instead.
let shared: Package.Dependency =
    ProcessInfo.processInfo.environment["PROJECT_LIFECYCLE_PACKAGE"].map { .package(path: $0) }
    ?? .package(url: "git@github.com:mrtysn/project-lifecycle.git", branch: "main")

let package = Package(
    name: "cc-statusline",
    platforms: [.macOS(.v13)],
    dependencies: [shared],
    targets: [
        .executableTarget(
            name: "AgentBarHopping",
            dependencies: [.product(name: "MacAppBase", package: "project-lifecycle")],
            path: "src",
            sources: ["main.swift"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
