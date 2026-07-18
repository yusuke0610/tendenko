# CLAUDE.md — tendenko 開発ガイド

tendenko は津波情報をトリガーに高台への避難を最短化する iOS アプリ。公式警報の代替ではなく、後追いで避難準備を自動化する係。

## 正本 (source of truth)

- **開発環境の正本は `flake.nix`**。ツールの追加・更新は必ず flake.nix で行う。Swift/Xcode だけは例外で、macOS の Xcode を前提とする (Nix で管理しない)
- **実行方法の正本は `Makefile`**。ビルド・テスト・lint 等のコマンドを README やドキュメントに直接書かないこと。ドキュメントからは `make <target>` を参照する
- `make help` で全ターゲットを確認できる

## 設計変更は ADR を経る

- アーキテクチャ・データフォーマット・依存関係・ライセンスなどの決定はすべて `docs/adr/` に記録する
- 新しい ADR は `make docs-adr` で連番作成する (template.md をコピー)
- 第三者がデューデリジェンスできる品質を維持する。決定の背景・選択肢・トレードオフを省略しない

## app/ の構成

- **Xcode プロジェクトの正本は `app/project.yml`** (XcodeGen)。`Tendenko.xcodeproj` は生成物でありコミットしない。ターゲット・依存・設定の変更は project.yml を編集して `make app-generate`
- ドメイン層は `app/TendenkoDomain/` のローカル Swift Package。macOS でもビルドできるため `make domain-test` でシミュレータなしに高速にテストが回る — TDD はまずここで
- UI 層 (`app/Tendenko/`) は SwiftUI + MapLibre Native (SPM)。アプリターゲットのテストは `make app-test` (要 iOS シミュレータランタイム: `xcodebuild -downloadPlatform iOS`)

## コード規約

- **app/ のドメイン層は純粋関数 + TDD**。経路探索・案内文生成などのロジックは副作用を持たない関数として書き、テストを先に書く
- **app/ にサーバー・インフラへの依存を持ち込まない**。サーバー側の都合 (API 形状、インフラ構成) がドメイン層に漏れない境界を維持する
- コミットメッセージは [Conventional Commits](https://www.conventionalcommits.org/ja/) (`feat:`, `fix:`, `docs:`, `chore:` 等)
- **`git push` は毎回ユーザーの明示的な承認を得てから行う**。過去に承認されていても次回に持ち越さない (コミットはローカルなので承認不要)
- Go コードは `make fmt` (gofmt) と `make server-lint` (golangci-lint) を通すこと

## 次セッションの最優先タスク

1. **pipeline の垂直スライス** — 実在の沿岸 2 次メッシュ 1 個で region.sqlite + MBTiles を end-to-end 生成し、サイズと生成時間を実測する (ADR-0003 の「正直な弱点」の検証)
2. **app/ の GraphLoader + EvacuationRouter** — SQLite → 隣接リスト展開と A* (動的コスト) をドメイン層 TDD で実装。NFR-03 (5 秒) のベンチマークも早期に書く
3. app/ の地図表示 (MapLibre + MBTiles オフライン読み込み)
