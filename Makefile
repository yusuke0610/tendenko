# tendenko — 実行方法の正本。コマンドはここに集約し、ドキュメントからは make <target> を参照する。
#
# 全レシピは nix develop (flake.nix の devShell) の中で実行される。
# 分岐 (nix シェル内なら二重起動しない / nix 不在の CI では素通し) は scripts/nix-bash.sh 側。
SHELL := ./scripts/nix-bash.sh

.DEFAULT_GOAL := help

.PHONY: help setup server-run server-test server-lint pipeline-run pipeline-run-one pipeline-test \
        pipeline-normalize-data app-generate app-build app-test domain-test infra-plan infra-apply docs-adr fmt

help: ## 全ターゲットの一覧と説明を表示
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

setup: ## 初回セットアップ (git hooks 等。nix develop は自動で適用される)
	@git config core.hooksPath .githooks 2>/dev/null || true
	@echo "setup done"

server-run: ## server/ subscriber をローカル実行
	cd server && go run ./cmd/subscriber

server-test: ## server/ のテストを実行
	cd server && go test ./...

server-lint: ## server/ を golangci-lint でチェック
	cd server && golangci-lint run ./...

pipeline-normalize-data: ## 浸水想定区域 (A40)・避難場所の実データを正規化 GeoJSON に変換 (要: data/a40/*.zip, data/raw/shelters-all.geojson。取得元は ADR-0003)
	cd pipeline && ./scripts/normalize-a40.sh
	cd pipeline && ./scripts/normalize-shelters.sh

# 一括: PBF に置いた OSM データの海岸線メッシュを全生成 (全国は japan-latest.osm.pbf を指定)。
# 浸水想定区域・避難場所の正規化データがあれば自動で使う (make pipeline-normalize-data で生成)。
PBF ?= pipeline/data/japan-latest.osm.pbf
INUNDATION := $(wildcard pipeline/data/inundation-japan.geojson)
SHELTERS := $(wildcard pipeline/data/shelters-japan.geojson)
pipeline-run: ## 地域パッケージを一括生成 (PBF=OSM pbf パス。沿岸メッシュ自動列挙 + manifest)
	cd pipeline && go run ./cmd/build-package -pbf $(abspath $(PBF)) -out out -dem-cache data/dem-cache \
		$(if $(INUNDATION),-inundation $(abspath $(INUNDATION))) \
		$(if $(SHELTERS),-shelters $(abspath $(SHELTERS)))

# 単一メッシュ (デバッグ用): make pipeline-run-one MESH=584177 (data/mesh-<MESH>.osm を切り出しておく)
MESH ?= 584177
pipeline-run-one: ## 単一メッシュの地域パッケージを生成 (MESH=2次メッシュコード)
	cd pipeline && go run ./cmd/build-package -mesh $(MESH) -osm data/mesh-$(MESH).osm -out out -dem-cache data/dem-cache

pipeline-test: ## pipeline/ のテストを実行
	cd pipeline && go test ./...

app-generate: ## Xcode プロジェクトを project.yml から生成 (XcodeGen)
	cd app && xcodegen generate

app-build: app-generate ## iOS アプリをシミュレータ向けにビルド (署名なし)
	cd app && xcodebuild -project Tendenko.xcodeproj -scheme Tendenko \
		-destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

domain-test: ## ドメイン層のテストを実行 (シミュレータ不要・高速。TDD はまずこれ)
	cd app/TendenkoDomain && swift test

app-test: app-generate domain-test ## ドメイン層 + アプリターゲットのテストを実行 (要 iOS シミュレータランタイム)
	cd app && xcodebuild -project Tendenko.xcodeproj -scheme Tendenko \
		-destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO

infra-plan: ## OpenTofu の plan を実行
	cd infra && tofu plan

infra-apply: ## OpenTofu の apply を実行
	cd infra && tofu apply

docs-adr: ## 新しい ADR を連番で作成 (template.md をコピー)
	@last=$$(ls docs/adr | grep -E '^[0-9]{4}-' | sort | tail -n1 | cut -c1-4); \
	next=$$(printf '%04d' $$((10#$$last + 1))); \
	cp docs/adr/template.md "docs/adr/$$next-title-me.md"; \
	echo "created docs/adr/$$next-title-me.md — ファイル名とタイトルを変更してください"

fmt: ## gofmt + nixfmt でフォーマット
	gofmt -w server pipeline
	nixfmt flake.nix
