# tendenko — 実行方法の正本。コマンドはここに集約し、ドキュメントからは make <target> を参照する。

.DEFAULT_GOAL := help

.PHONY: help setup server-run server-test server-lint pipeline-run pipeline-test \
        app-build app-test infra-plan infra-apply docs-adr fmt

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

pipeline-run: ## 地域パッケージ生成を実行
	cd pipeline && go run ./cmd/build-package

pipeline-test: ## pipeline/ のテストを実行
	cd pipeline && go test ./...

app-build: ## iOS アプリをビルド (TODO: Xcode プロジェクト生成後に実装)
	@echo "TODO: app/ の Xcode プロジェクト生成後に xcodebuild ラッパーを実装する"

app-test: ## iOS アプリのテストを実行 (TODO: Xcode プロジェクト生成後に実装)
	@echo "TODO: app/ の Xcode プロジェクト生成後に xcodebuild test ラッパーを実装する"

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
