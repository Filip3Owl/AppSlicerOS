// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppSlicerOS",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppSlicerML", targets: ["AppSlicerML"]),
        .library(name: "AppSlicerMetrics", targets: ["AppSlicerMetrics"]),
        .library(name: "AppSlicerHistory", targets: ["AppSlicerHistory"]),
        .executable(name: "appslicer-collector", targets: ["AppSlicerCollector"]),
        .executable(name: "appslicer-app", targets: ["AppSlicerApp"]),
    ],
    targets: [
        .target(name: "AppSlicerML"),
        .target(name: "AppSlicerMetrics"),
        .target(name: "AppSlicerHistory", dependencies: ["AppSlicerMetrics"]),
        .executableTarget(
            name: "AppSlicerCollector",
            dependencies: ["AppSlicerHistory", "AppSlicerML", "AppSlicerMetrics"]
        ),
        .executableTarget(
            name: "AppSlicerApp",
            dependencies: ["AppSlicerHistory", "AppSlicerML", "AppSlicerMetrics"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "AppSlicerMLTests", dependencies: ["AppSlicerML"]),
        .testTarget(name: "AppSlicerMetricsTests", dependencies: ["AppSlicerMetrics"]),
        .testTarget(name: "AppSlicerHistoryTests", dependencies: ["AppSlicerHistory", "AppSlicerMetrics"]),
        .testTarget(name: "AppSlicerAppTests", dependencies: ["AppSlicerApp", "AppSlicerMetrics"]),
        .testTarget(
            name: "AppSlicerCollectorTests",
            dependencies: ["AppSlicerCollector", "AppSlicerHistory", "AppSlicerML", "AppSlicerMetrics"]
        ),
    ]
)
