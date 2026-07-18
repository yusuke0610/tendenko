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

## コード規約

- **app/ のドメイン層は純粋関数 + TDD**。経路探索・案内文生成などのロジックは副作用を持たない関数として書き、テストを先に書く
- **app/ にサーバー・インフラへの依存を持ち込まない**。サーバー側の都合 (API 形状、インフラ構成) がドメイン層に漏れない境界を維持する
- コミットメッセージは [Conventional Commits](https://www.conventionalcommits.org/ja/) (`feat:`, `fix:`, `docs:`, `chore:` 等)
- Go コードは `make fmt` (gofmt) と `make server-lint` (golangci-lint) を通すこと

## 次セッションの最優先タスク

1. **データパイプライン設計** — 地域分割単位・道路グラフフォーマットを ADR-0003 として決定する
2. **Xcode プロジェクトの生成** — app/ ディレクトリの立ち上げ (SwiftUI + MapLibre Native、ドメイン層の TDD 基盤)
