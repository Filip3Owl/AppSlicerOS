// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppSlicerOS",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppSlicerML", targets: ["AppSlicerML"]),
    ],
    targets: [
        .target(name: "AppSlicerML"),
        .testTarget(name: "AppSlicerMLTests", dependencies: ["AppSlicerML"]),
    ]
)
