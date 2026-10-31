// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppSlicerOS",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppSlicerML", targets: ["AppSlicerML"]),
        .library(name: "AppSlicerMetrics", targets: ["AppSlicerMetrics"]),
        .executable(name: "appslicer-collector", targets: ["AppSlicerCollector"]),
    ],
    targets: [
        .target(name: "AppSlicerML"),
        .target(name: "AppSlicerMetrics"),
        .executableTarget(name: "AppSlicerCollector", dependencies: ["AppSlicerMetrics"]),
        .testTarget(name: "AppSlicerMLTests", dependencies: ["AppSlicerML"]),
        .testTarget(name: "AppSlicerMetricsTests", dependencies: ["AppSlicerMetrics"]),
        .testTarget(
            name: "AppSlicerCollectorTests",
            dependencies: ["AppSlicerCollector", "AppSlicerMetrics"]
        ),
    ]
)
