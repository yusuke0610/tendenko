// swift-tools-version:6.0
// TendenkoDomain: ドメイン層 — 純粋関数 + TDD。依存ゼロを維持する (CLAUDE.md)。
// TendenkoStorage: region.sqlite → RoadGraph のローダー。GRDB 依存はここに隔離する。
// どちらも macOS でビルドできるため、テストはシミュレータ不要で `swift test` で回せる。
import PackageDescription

let package = Package(
    name: "TendenkoDomain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TendenkoDomain", targets: ["TendenkoDomain"]),
        .library(name: "TendenkoStorage", targets: ["TendenkoStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")
    ],
    targets: [
        .target(name: "TendenkoDomain"),
        .target(
            name: "TendenkoStorage",
            dependencies: [
                "TendenkoDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "TendenkoDomainTests", dependencies: ["TendenkoDomain"]),
        .testTarget(name: "TendenkoStorageTests", dependencies: ["TendenkoStorage"]),
    ]
)
