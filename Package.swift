// swift-tools-version:6.2
import PackageDescription

let featureNames = [
    "ConnectionsFeature",
    "BrowserFeature",
    "KeyTypesBasicFeature",
    "KeyTypesAdvancedFeature",
    "WorkbenchFeature",
    "CLIFeature",
    "AnalyticsFeature",
    "MonitoringFeature",
    "VectorSearchFeature",
    "SettingsFeature",
]

let featureResources: [String: [Resource]] = [
    "BrowserFeature": [.copy("Resources/SampleData")],
    "WorkbenchFeature": [.copy("Resources/Tutorials")],
    "AnalyticsFeature": [.process("Resources")],
    "VectorSearchFeature": [.copy("Resources/SampleData")],
]

let featureTargets: [Target] = featureNames.map { name in
    .target(
        name: name,
        dependencies: ["RedisCore", "RedisUI"],
        path: "Sources/Features/\(name)",
        resources: featureResources[name]
    )
}

let featureTestTargets: [Target] = featureNames.map { name in
    .testTarget(
        name: "\(name)Tests",
        dependencies: [.target(name: name), "RedisCore", "TestSupport"],
        path: "Tests/\(name)Tests"
    )
}

let package = Package(
    name: "KeystrandKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AppShell", targets: ["AppShell"]),
        .library(name: "RedisCore", targets: ["RedisCore"]),
    ],
    targets: [
        .target(name: "RESP", path: "Sources/RESP"),
        .target(name: "RedisClient", dependencies: ["RESP"], path: "Sources/RedisClient"),
        .target(name: "Formatters", dependencies: ["RESP"], path: "Sources/Formatters"),
        .target(
            name: "CommandSpecs",
            dependencies: ["RESP"],
            path: "Sources/CommandSpecs",
            resources: [.copy("Resources/Commands")]
        ),
        .target(
            name: "RedisCore",
            dependencies: ["RESP", "RedisClient", "Formatters", "CommandSpecs"],
            path: "Sources/RedisCore"
        ),
        .target(name: "RedisUI", dependencies: ["RedisCore"], path: "Sources/RedisUI"),
        .target(
            name: "AppShell",
            dependencies: ["RedisCore", "RedisUI"] + featureNames.map { .target(name: $0) },
            path: "Sources/AppShell"
        ),
        .target(name: "TestSupport", dependencies: ["RedisCore"], path: "Tests/TestSupport"),

        .testTarget(name: "RESPTests", dependencies: ["RESP", "TestSupport"], path: "Tests/RESPTests"),
        .testTarget(name: "RedisClientTests", dependencies: ["RedisClient", "TestSupport"], path: "Tests/RedisClientTests"),
        .testTarget(name: "FormattersTests", dependencies: ["Formatters", "TestSupport"], path: "Tests/FormattersTests"),
        .testTarget(name: "CommandSpecsTests", dependencies: ["CommandSpecs", "TestSupport"], path: "Tests/CommandSpecsTests"),
        .testTarget(name: "RedisCoreTests", dependencies: ["RedisCore", "TestSupport"], path: "Tests/RedisCoreTests"),
        .testTarget(name: "RedisUITests", dependencies: ["RedisUI", "TestSupport"], path: "Tests/RedisUITests"),
        .testTarget(
            name: "AppShellTests",
            dependencies: ["AppShell", "RedisCore", "ConnectionsFeature", "SettingsFeature", "TestSupport"],
            path: "Tests/AppShellTests"
        ),
    ] + featureTargets + featureTestTargets,
    swiftLanguageModes: [.v6]
)
