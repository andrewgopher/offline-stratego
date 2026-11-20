// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OfflineBarrage",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .executable(name: "OfflineBarrage", targets: ["OfflineBarrage"]),
        .library(name: "BarrageCore", targets: ["BarrageCore"]),
        // Used by the iPhone/iPad app (iOS/OfflineBarrage.xcodeproj), which compiles the
        // OfflineBarrage sources itself.
        .library(name: "PeerKit", targets: ["PeerKit"]),
    ],
    targets: [
        // Pure-Swift rules, setup commitments, clocks and the two-player match protocol.
        // Depends only on Foundation and CryptoKit, so it is unit-testable without the UI.
        .target(name: "BarrageCore"),
        // Discovery of nearby players and links over MultipeerConnectivity (peer-to-peer Wi-Fi).
        .target(name: "PeerKit", dependencies: ["BarrageCore"]),
        // The SwiftUI app: UI, game flow, persistence. Built here for macOS; the iOS app target
        // in iOS/OfflineBarrage.xcodeproj compiles these same sources.
        .executableTarget(name: "OfflineBarrage", dependencies: ["BarrageCore", "PeerKit"]),
        // Headless two-process check of PeerKit + the match protocol.
        .executableTarget(name: "PeerSmokeTest", dependencies: ["BarrageCore", "PeerKit"]),
        .testTarget(name: "BarrageCoreTests", dependencies: ["BarrageCore"]),
    ]
)
