# Swift/iOS ルール (app/)

- Xcode プロジェクトの正本は `app/project.yml` (XcodeGen)。`Tendenko.xcodeproj` は生成物でありコミットしない。ターゲット・依存・設定の変更は `project.yml` を編集して `make app-generate` で再生成する
- Swift 6.0 (`SWIFT_VERSION: "6.0"`)、iOS 17.0 以降が対象 (`options.deploymentTarget.iOS`)
- **ドメイン層 (`app/TendenkoDomain/`) は純粋関数 + TDD**。経路探索・案内文生成などのロジックは副作用を持たない関数として書き、テストを先に書く。macOS 上でシミュレータなしに `make domain-test` で高速に回せるため、新規ロジックはまずここで書く (詳細は [testing.md](testing.md))
- **`app/` にサーバー・インフラへの依存を持ち込まない**。サーバー側の都合 (API 形状、インフラ構成) がドメイン層に漏れない境界を維持する
- UI 層 (`app/Tendenko/`) は SwiftUI + MapLibre Native (SPM)。MapLibre は `project.yml` の `packages.MapLibre.from: 6.0.0` でピン留めしており、**Renovate の管理対象外** (XcodeGen の `project.yml` を読めるマネージャが無い) なので更新は手動で行う
- フォントグリフ (ADR-0006) など、ディレクトリ構造を保ったまま同梱する必要のあるリソースは `project.yml` で folder reference (`type: folder`) にする。個別ファイル参照だとバンドルルートにフラット化され `<fontstack>/<range>.pbf` のような相対パスが壊れる
