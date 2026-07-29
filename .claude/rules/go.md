# Go ルール (server/, pipeline/)

- `server/go.mod` (go 1.23) と `pipeline/go.mod` (go 1.25.0) は独立した Go module。それぞれ個別に依存管理する
- フォーマットは `make fmt` (gofmt) を必ず通す。CI も `gofmt -l server pipeline` で差分があれば fail する
- lint は golangci-lint。設定はリポジトリ直下の `.golangci.yml` 1 箇所 (golangci-lint が上位ディレクトリの設定を自動探索するため、server/pipeline 両方に同じ設定が適用される)
  - `errcheck` は defer での `Close`/`Rollback` など「失敗しても対処のしようがない」呼び出しを除外リスト化している。新たに同種の defer を書く場合は除外リストへの追加要否を検討する
- テストは `make server-test` / `make pipeline-test` (CI でも同名ターゲットを実行。詳細は [testing.md](testing.md))
- `pipeline/` は GDAL・osmium など外部ツールに依存し、tilemaker (`-tiles` オプション) は macOS/arm64 でクラッシュするため **Linux 専用** (ADR-0003)。ローカル macOS で `-tiles` 付きの動作を試す場合は `make pipeline-run-docker` や `make pipeline-tiles-one` を使う。本番実行は Cloud Run jobs (Linux コンテナ) 前提
- `server/`・`pipeline/` に app/ (Swift ドメイン層) 側の都合を持ち込まない。責務境界は API 形状・データフォーマットで区切る
