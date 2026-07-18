# tendenko — 実行方法の正本。コマンドはここに集約し、ドキュメントからは make <target> を参照する。

.DEFAULT_GOAL := help

.PHONY: help setup server-run server-test server-lint pipeline-run pipeline-test \
        app-generate app-build app-test domain-test infra-plan infra-apply docs-adr fmt

help: ## 全ターゲットの一覧と説明を表示
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

setup: ## 初回セットアップ (nix develop 内であることを検証し、git hooks を設定)
	@if [ -z "$$IN_NIX_SHELL" ]; then \
		echo "error: nix develop (または direnv) のシェル内で実行してください"; exit 1; \
	fi
	@git config core.hooksPath .githooks 2>/dev/null || true
	@echo "setup done"

server-run: ## server/ subscriber をローカル実行
	cd server && go run ./cmd/subscriber

server-test: ## server/ のテストを実行
	cd server && go test ./...

server-lint: ## server/ を golangci-lint でチェック
	cd server && golangci-lint run ./...

# 例: make pipeline-run MESH=584177 (data/mesh-<MESH>.osm を osmium で切り出しておくこと)
MESH ?= 584177
pipeline-run: ## 地域パッケージ生成を実行 (MESH=2次メッシュコード)
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
