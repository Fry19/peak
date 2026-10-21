// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PeakCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PeakCore", targets: ["PeakCore"]),
        .executable(name: "peakbench", targets: ["peakbench"]),
    ],
    targets: [
        .target(name: "PeakCore"),
        .executableTarget(name: "peakbench", dependencies: ["PeakCore"]),
        .testTarget(name: "PeakCoreTests", dependencies: ["PeakCore"]),
    ]
)
