# infra/

OpenTofu によるインフラ定義。

構成は [ADR-0001](../docs/adr/0001-execution-platform.md) の **Stage 1 (MVP)** に従う:

- subscriber + fanout は Cloud Run service に同居 (単一リージョン asia-northeast1、min-instances=1、CPU always allocated)
- pipeline は Cloud Run jobs + Cloud Scheduler
- フォールバックの気象庁 XML ポーリングも Cloud Scheduler + Cloud Run jobs (60 秒間隔)

実行は Makefile 経由 (`make infra-plan` / `make infra-apply`)。
