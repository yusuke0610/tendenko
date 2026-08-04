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

## 責務ごとのルール

言語・領域ごとの詳細ルールは `.claude/rules/` に分割している (このファイルが正本を兼ねず内容が分散しないよう、以下は要約ではなく実体への参照)。

- @.claude/rules/go.md — Go (server/, pipeline/) のフォーマット・lint・テスト・実行環境の注意点
- @.claude/rules/swift.md — Swift/iOS (app/) のプロジェクト構成・ドメイン層 TDD・依存境界
- @.claude/rules/testing.md — テストコマンドと CI カバレッジの対応表
- @.claude/rules/contributing.md — ブランチ・コミット・PR・CI/CodeRabbit 対応の運用ルール

CI (GitHub Actions, `.github/workflows/ci.yml`) は make ターゲットを呼ぶだけの薄いラッパーに保つ。テスト・ビルド手順を workflow に直接書かない。

## 次セッションの最優先タスク

1. **FR-02 (地域パッケージの自動ダウンロード)** — **アプリ側実装は完了** (ADR-0004。MeshCode/CachePlanner/RegionPackageStore/GCSPackageFetcher/RegionCacheCoordinator)。ContentView は現在地メッシュのパッケージを DL してキャッシュから表示し、未取得時は同梱サンプル (584177) にフォールバックする。残: (a) 実 GCS 接続 — infra `tofu apply` + パッケージ upload 後に `AppConfig.packagesBaseURL` を設定 (要 GCP 認証)、(b) A40 条件付き県の除外 (ADR-0002、public 再生成の前提)
2. **FR-14 (経路逸脱リルート) / FR-16 (目的地到達検知)** — 音声案内 (FR-13) は実装済み (ADR-0007。`GuidanceScript` + `SpeechAnnouncer`)。**判定のドメイン層も実装済み** (`RouteTracking.swift` の `RouteTracker.track`。逸脱・到達・案内の進行・次の指示までの残距離を返す純粋関数、`RouteGeometry.distanceToPolylineM` / `progressAlongPolylineM` / `GeoPoint.distanceM` を追加)。**残るのは UI 層の配線**:
   - `RegionCacheCoordinator` は `requestLocation()` の単発測位 + significant location change しか使っていない。FR-14 の「3 秒以内にリルート」には案内フェーズ中の連続測位 (`startUpdatingLocation`) が要るが、NFR-05 は平時の常時 GPS を禁じている。**「案内フェーズ中だけ連続測位に切り替える」判断は ADR に起こしてから実装する**
   - `TrackingState.stepIndex` の進みに合わせて `SpeechAnnouncer` で順次発話する。逸脱時は `EvacuationRouter` を再実行してリルート
   - ADR-0007 の残課題「実データで 3,000m の無案内区間」は `TrackingState.distanceToNextStepM` を使った進捗案内で解消できる。都市部 (分岐点が密) での案内過多は未確認のまま
   - MapView の可読性向上 (経路の可視化・avoid-inundation 色分け・地名/道路名ラベル、ADR-0006) は実装・実機確認済み (`cc5be98`, `cd4de30`)。未確認で残るのは道路名 (`transportation_name`) の実機確認 (前回のビューポートに主要道路が入らず未確認) と、都市部でのラベル密度・過密の調整のみ
3. **全国 2,515 パッケージへの MBTiles 本番適用**: 実装・ローカル検証は完了 (ADR-0003)。**準備状況 (2026-07-29 確認)**: Docker イメージ (`make pipeline-image`) はローカルビルド成功済み。`infra/environments/production` は `tofu init`/`validate` まで通過済みだが **`terraform.tfvars` 未作成・`tofu apply` 未実行 (課金なし)**。残作業: (a) 本番 GCP プロジェクト ID の決定 (現状 gcloud アクティブプロジェクトは `devforge-dev-20260311` だが tendenko 用と確定していない — ユーザー確認要)、(b) `terraform.tfvars` 作成 → `tofu apply`、(c) イメージを Artifact Registry へ push、(d) 全国 japan pbf に対して `-tiles` 付きジョブを実行 (ローカル実測 61 分、Cloud Run 実行時間・GCS 課金が発生する不可逆に近い操作なのでユーザー確認の上で実施)
4. **東京都・福井県・香川県の津波浸水想定区域データの補完** — **福井県は実装済み** (`normalize-fukui.sh`、ADR-0003 追記 2026-07-28、敦賀メッシュで動作確認済み)。**東京都・香川県はラスタ→ポリゴン変換パイプラインの設計を完了** (ADR-0003 追記 2026-07-29): 凡例 (6 段階、国交省「水害ハザードマップ作成の手引き」令和5年5月改定) の RGB 値・タイル取得〜dissolve までの変換手順・未解決事項 (RGB 表の一次情報照合、東京都本土部のカバレッジ、色の許容誤差、zoom 確定、PDL1.0 のライセンス表記) を整理済み。実装 (`fetch-tsunami-raster.sh` / `normalize-raster-tsunami.sh` の作成) は未着手
