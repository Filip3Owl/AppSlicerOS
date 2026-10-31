// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppSlicerOS",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppSlicerML", targets: ["AppSlicerML"]),
        .library(name: "AppSlicerMetrics", targets: ["AppSlicerMetrics"]),
        .library(name: "AppSlicerHistory", targets: ["AppSlicerHistory"]),
        .executable(name: "appslicer-collector", targets: ["AppSlicerCollector"]),
    ],
    targets: [
        .target(name: "AppSlicerML"),
        .target(name: "AppSlicerMetrics"),
        .target(name: "AppSlicerHistory", dependencies: ["AppSlicerMetrics"]),
        .executableTarget(
            name: "AppSlicerCollector",
            dependencies: ["AppSlicerHistory", "AppSlicerML", "AppSlicerMetrics"]
        ),
        .testTarget(name: "AppSlicerMLTests", dependencies: ["AppSlicerML"]),
        .testTarget(name: "AppSlicerMetricsTests", dependencies: ["AppSlicerMetrics"]),
        .testTarget(name: "AppSlicerHistoryTests", dependencies: ["AppSlicerHistory", "AppSlicerMetrics"]),
        .testTarget(
            name: "AppSlicerCollectorTests",
            dependencies: ["AppSlicerCollector", "AppSlicerHistory", "AppSlicerML", "AppSlicerMetrics"]
        ),
    ]
)
