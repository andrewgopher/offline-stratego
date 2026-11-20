// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OfflineBarrage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OfflineBarrage", targets: ["OfflineBarrage"]),
        .library(name: "BarrageCore", targets: ["BarrageCore"]),
    ],
    targets: [
        // Pure-Swift rules, setup commitments, clocks and the two-player match protocol.
        // Depends only on Foundation and CryptoKit, so it is unit-testable without the UI.
        .target(name: "BarrageCore"),
        // Nearby-Mac discovery and a 1:1 link over MultipeerConnectivity (peer-to-peer Wi-Fi).
        .target(name: "PeerKit", dependencies: ["BarrageCore"]),
        // The macOS SwiftUI app: UI, game flow, persistence.
        .executableTarget(name: "OfflineBarrage", dependencies: ["BarrageCore", "PeerKit"]),
        // Headless two-process check of PeerKit + the match protocol.
        .executableTarget(name: "PeerSmokeTest", dependencies: ["BarrageCore", "PeerKit"]),
        .testTarget(name: "BarrageCoreTests", dependencies: ["BarrageCore"]),
    ]
)
