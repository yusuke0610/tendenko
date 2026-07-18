// swift-tools-version:6.0
// ドメイン層 — 純粋関数 + TDD。サーバー・インフラ・UIKit への依存を持ち込まない (CLAUDE.md)。
// macOS でもビルドできるため、テストはシミュレータ不要で `swift test` で回せる。
import PackageDescription

let package = Package(
    name: "TendenkoDomain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TendenkoDomain", targets: ["TendenkoDomain"])
    ],
    targets: [
        .target(name: "TendenkoDomain"),
        .testTarget(name: "TendenkoDomainTests", dependencies: ["TendenkoDomain"]),
    ]
)
