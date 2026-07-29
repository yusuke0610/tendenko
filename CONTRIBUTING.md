# Contributing

tendenko への貢献ありがとうございます。このドキュメントは開発の始め方と、このリポジトリ固有の運用ルールをまとめたものです。より詳細な規約 ([正本](#正本-source-of-truth) の考え方や AI アシスタント向けの指示を含む) は [CLAUDE.md](CLAUDE.md) にあります。人間のコントリビューターにも同じ規約が適用されるので、あわせて参照してください。

## 開発環境のセットアップ

開発環境の正本は `flake.nix`、実行方法の正本は `Makefile` です。ツールのバージョンや追加は必ず `flake.nix` で管理し、README や本ドキュメントにコマンドを直接書きません。

```sh
# Nix + direnv がある場合
direnv allow

# direnv を使わない場合
nix develop
```

シェルに入ったら:

```sh
make help   # 全ターゲットの一覧と説明
make setup  # 初回セットアップ
```

Swift/Xcode だけは例外で Nix では管理しません。iOS アプリ (`app/`) のビルドには macOS + Xcode が必要です。

## 正本 (source of truth)

変更対象によって編集すべきファイルが決まっています。生成物を直接編集しないでください。

| 対象 | 正本 | 生成コマンド |
|---|---|---|
| 開発環境・ツール | `flake.nix` | `nix develop` |
| ビルド・テスト・lint 等の実行方法 | `Makefile` | `make <target>` |
| Xcode プロジェクト | `app/project.yml` (XcodeGen) | `make app-generate` (`Tendenko.xcodeproj` はコミットしない) |
| 設計・アーキテクチャ判断 | `docs/adr/` | `make docs-adr` で新規ADR作成 |

## 変更の進め方

1. `main` から作業ブランチを切る (`main` に直接コミットしない)。ブランチ名はコミットメッセージの prefix に合わせる (`feat/...`, `fix/...`, `docs/...`, `chore/...` 等)
2. アーキテクチャ・データフォーマット・依存関係・ライセンスなど設計に関わる決定は `docs/adr/` に ADR として記録する。背景・選択肢・トレードオフを省略せず、第三者がデューデリジェンスできる品質を保つ
3. `app/` のドメイン層 (`app/TendenkoDomain/`) は純粋関数 + TDD で書く。経路探索・案内文生成などのロジックはテストを先に書く。`app/` にサーバー・インフラ側の都合 (API 形状、インフラ構成) を持ち込まない
4. コミットメッセージは [Conventional Commits](https://www.conventionalcommits.org/ja/) (`feat:`, `fix:`, `docs:`, `chore:` 等) に従う
5. Go コードは `make fmt` (gofmt) と golangci-lint (`.golangci.yml`) を通す

## テスト

- `make domain-test` — `app/TendenkoDomain/` のドメイン層テスト。macOS でもシミュレータなしに高速に回る。iOS アプリ機能の TDD はまずここで行う
- `make app-test` — アプリターゲットのテスト (要 iOS シミュレータランタイム: `xcodebuild -downloadPlatform iOS`)
- `make server-test` / `make pipeline-test` — Go 側のテスト

## PRを出す・CIとCodeRabbitへの対応

- CI (`.github/workflows/ci.yml`) は make ターゲットを呼ぶだけの薄いラッパーです。Go (server + pipeline)・iOS ドメイン層・iOS アプリビルドの3ジョブが `pull_request` で走ります
- PRを作成・更新したら、CIのステータスと CodeRabbit のレビューコメントの両方を確認してください。指摘が残っている間は「確認 → 妥当性を判断 → 必要なら修正してコミット・push → 再確認」を、両方グリーンになるまで繰り返します
- CodeRabbit の指摘は鵜呑みにせず、妥当性を判断してから対応してください。的外れな指摘は理由を添えて却下して構いません

## ライセンス

本リポジトリのライセンスは現時点で**未決**です ([ADR-0002](docs/adr/0002-oss-licensing.md) 参照)。決定するまで `LICENSE` ファイルは置いていません。
