# テストのルール

| コマンド | 対象 | 実行環境 | CI での実行 |
|---|---|---|---|
| `make domain-test` | `app/TendenkoDomain/` (ドメイン層) | macOS、シミュレータ不要 | ✅ (macos-15) |
| `make app-test` | `app/Tendenko` アプリターゲット | iOS シミュレータ (要 `xcodebuild -downloadPlatform iOS`) | ❌ 未実行 (CI は `make app-build` のみ) |
| `make server-test` | `server/` | - | ✅ (ubuntu-latest) |
| `make pipeline-test` | `pipeline/` | - | ✅ (ubuntu-latest) |

- **TDD はドメイン層 (`TendenkoDomain`) から始める**。`make domain-test` はシミュレータ不要で高速に回るため、経路探索・案内文生成などのロジックはここでテストを先に書いてから実装する
- **`make app-test` は CI で実行されていない** (iOS シミュレータランタイムのダウンロードが重いため、CI の `app` ジョブは `make app-build` = ビルドのみ)。UI 層のロジックを変更した場合は、ローカルで `make app-test` を明示的に走らせて確認する。UI や MapView など見た目に関わる変更は、実際にシミュレータで動かして確認する (型チェックやテストはコードの正しさしか保証せず、機能としての正しさは保証しない)
- Go 側 (`server/`, `pipeline/`) はテストに加えて `make fmt` と golangci-lint も通す ([go.md](go.md) 参照)
