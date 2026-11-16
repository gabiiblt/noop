// swift-tools-version: 5.9
import PackageDescription

// Client side of the self-hosted one-way push (docs/PUSH_PROTOCOL.md v1 + selfhost/PROTOCOL_EXT.md).
// Pure logic + a read-only GRDB row source; the app glue lives in StrandiOS/Push/.
let package = Package(
    name: "SelfHostPush",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "SelfHostPush", targets: ["SelfHostPush"])],
    dependencies: [
        // Supply-chain: pinned EXACT, same version as the other Packages/*/Package.swift and project.yml.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        .package(path: "../WhoopStore"),
    ],
    targets: [
        .target(
            name: "SelfHostPush",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "SelfHostPushTests",
            dependencies: [
                "SelfHostPush",
                .product(name: "WhoopStore", package: "WhoopStore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Parity")]
        ),
    ]
)
