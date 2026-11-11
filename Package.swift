// swift-tools-version:6.0
//
//  NovaAIKit — one AI feature set for every Jordan Koch app.
//  Copyright © 2026 Jordan Koch. MIT licensed.
//

import PackageDescription

let package = Package(
    name: "NovaAIKit",
    // The lowest targets among the adopting apps that the current Xcode (27) can build: macOS 12 is Xcode 27's floor
    // (Stream Rotator / RTSP Rotator declare 11.0 and must move to 12.0 when they adopt), GTNW iOS is 15.
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
    ],
    products: [
        /// Core: backends, Auto failover, retries, Keychain keys, status, validation/fallback, SwiftUI views.
        .library(name: "NovaAIKit", targets: ["NovaAIKit"]),
        /// Optional on-device MLX helpers (macOS): launches/stops `mlx_lm.server` and plugs any in-process engine in.
        .library(name: "NovaAIKitMLX", targets: ["NovaAIKitMLX"]),
    ],
    targets: [
        .target(name: "NovaAIKit"),
        .target(name: "NovaAIKitMLX", dependencies: ["NovaAIKit"]),
        .testTarget(name: "NovaAIKitTests", dependencies: ["NovaAIKit", "NovaAIKitMLX"]),
    ],
    swiftLanguageModes: [.v6]
)
