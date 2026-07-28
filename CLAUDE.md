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
- **作業は main から作業ブランチ (feature branch) を切って行う**。main に直接コミットしない。ブランチ名は `feat/...`・`fix/...` 等コミットメッセージの prefix に合わせる。作業完了後は PR 経由で main にマージする
- **`git push` は毎回ユーザーの明示的な承認を得てから行う**。過去に承認されていても次回に持ち越さない (コミットはローカルなので承認不要)
- Go コードは `make fmt` (gofmt) と golangci-lint (設定はリポジトリ直下の `.golangci.yml`) を通すこと
- CI (GitHub Actions, `.github/workflows/ci.yml`) は make ターゲットを呼ぶだけの薄いラッパーに保つ。テスト・ビルド手順を workflow に直接書かない

## 次セッションの最優先タスク

1. **FR-02 (地域パッケージの自動ダウンロード)** — **アプリ側実装は完了** (ADR-0004。MeshCode/CachePlanner/RegionPackageStore/GCSPackageFetcher/RegionCacheCoordinator)。ContentView は現在地メッシュのパッケージを DL してキャッシュから表示し、未取得時は同梱サンプル (584177) にフォールバックする。残: (a) 実 GCS 接続 — infra `tofu apply` + パッケージ upload 後に `AppConfig.packagesBaseURL` を設定 (要 GCP 認証)、(b) A40 条件付き県の除外 (ADR-0002、public 再生成の前提)
2. **MapView の可読性向上**: 経路の可視化 (青線) と avoid-inundation 色分け (赤線) は **実装済み** (`cc5be98`、ContentView.computeOverlay + MapView)。残るは**地名・道路名のテキストラベル表示** (ADR-0006)。同梱タイル (OpenMapTiles スキーマ) には地名・POI データが既に入っていることを確認済みで、pipeline 側の変更は不要。CJK フォントグリフの同梱とローカル配信 (`GlyphServer`、`MBTilesServer` と同パターン)、フォントのライセンス一次情報確認が実装前に必要
3. 全国 2,515 パッケージへの MBTiles 本番適用 (Cloud Run jobs で `-tiles` 付きの `make pipeline-run`。ローカル macOS では tilemaker が動かないため要 Linux 環境、ADR-0003 参照)
4. **東京都・福井県・香川県の津波浸水想定区域データの補完** — **福井県は実装済み** (`normalize-fukui.sh`、ADR-0003 追記 2026-07-28、敦賀メッシュで動作確認済み)。**東京都・香川県も取得は可能と判明** (ADR-0003 追記 2026-07-28): 国土地理院「ハザードマップポータルサイト」がラスタタイル (PNG, PDL1.0) で配信しており実データ取得・目視確認済み。ただし Shapefile ではなくラスタのため、色凡例の閾値処理 → ポリゴン化という追加の変換工程が必要 (福井より重い作業、未着手・未設計)。優先度は他タスク (2, 3) より低い
