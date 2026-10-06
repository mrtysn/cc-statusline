// swift-tools-version: 6.1
import Foundation
import PackageDescription

// project-lifecycle builds with PROJECT_LIFECYCLE_PACKAGE set to its own checkout, so the
// shared package comes from disk. A plain `swift build` fetches it instead.
let senders: Set<Package.Dependency.Trait> = [
    .trait(name: "OperationalReports", condition: .when(traits: ["OperationalReports"])),
    .trait(name: "UsageAnalytics", condition: .when(traits: ["UsageAnalytics"])),
]

let shared: Package.Dependency =
    ProcessInfo.processInfo.environment["PROJECT_LIFECYCLE_PACKAGE"].map { .package(path: $0, traits: senders) }
    ?? .package(url: "git@github.com:mrtysn/project-lifecycle.git", branch: "main", traits: senders)

let package = Package(
    name: "cc-statusline",
    platforms: [.macOS(.v13)],
    // The two senders are traits, on by default and forwarded to the shared package, so
    // `project-lifecycle build --without-reports --without-analytics` makes a lighter build.
    traits: [
        .trait(name: "OperationalReports", description: "Report launches, failures and heartbeats to the receiver"),
        .trait(name: "UsageAnalytics", description: "Send what people do to PostHog, once they opt in"),
        .default(enabledTraits: ["OperationalReports", "UsageAnalytics"]),
    ],
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
