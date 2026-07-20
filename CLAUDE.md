# CLAUDE.md — tendenko 開発ガイド

tendenko は津波情報をトリガーに高台への避難を最短化する iOS アプリ。公式警報の代替ではなく、後追いで避難準備を自動化する係。

## 正本 (source of truth)

- **開発環境の正本は `flake.nix`**。ツールの追加・更新は必ず flake.nix で行う。Swift/Xcode だけは例外で、macOS の Xcode を前提とする (Nix で管理しない)
- **実行方法の正本は `Makefile`**。ビルド・テスト・lint 等のコマンドを README やドキュメントに直接書かないこと。ドキュメントからは `make <target>` を参照する
- make は全レシピを自動で `nix develop` 内で実行する (SHELL = `scripts/nix-bash.sh`)。手動でシェルに入る必要はない。nix シェル内では二重起動せず、nix の無い CI では素通しになる。Xcode 系は shellHook が DEVELOPER_DIR を実 Xcode に戻すことで devShell 内でも動く
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
- Go コードは `make fmt` (gofmt) と golangci-lint (設定はリポジトリ直下の `.golangci.yml`) を通すこと
- CI (GitHub Actions, `.github/workflows/ci.yml`) は make ターゲットを呼ぶだけの薄いラッパーに保つ。テスト・ビルド手順を workflow に直接書かない

## 次セッションの最優先タスク

1. **全国パッケージの再生成** — 浸水想定区域・避難場所の実データ (国土数値情報 A40 + 国土地理院、取得・正規化スクリプトは `pipeline/scripts/normalize-*.sh`) を組み込んだ状態で `make pipeline-run` を全国 pbf で再実行し、manifest / ADR-0003 に実測を追記する
2. MBTiles (nixpkgs tilemaker は macOS/arm64 でクラッシュ → Linux で実測)
3. app/ の地図表示 (MapLibre + MBTiles オフライン読み込み)
