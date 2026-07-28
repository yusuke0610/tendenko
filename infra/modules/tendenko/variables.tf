variable "project_id" {
  type        = string
  description = "GCP プロジェクト ID"
}

variable "region" {
  type        = string
  default     = "asia-northeast1"
  description = "デフォルトリージョン (ADR-0001 Stage 1)"
}

variable "packages_bucket_name" {
  type        = string
  description = "地域パッケージ (region.sqlite / tiles.mbtiles) と manifest.json を配信するバケット名。GCS はグローバル一意 (例: tendenko-packages-<project>)"
}

variable "data_bucket_name" {
  type        = string
  description = "パイプラインの入力データ (japan-latest.osm.pbf / inundation-japan.geojson / shelters-japan.geojson / DEM キャッシュ) を置くバケット名。グローバル一意"
}

variable "packages_public" {
  type        = bool
  default     = true
  description = "配信バケットを公開読み取り (allUsers:objectViewer) にするか。production は ODbL の無償入手要件で true (ADR-0002/0005)。staging も true だが別バケット・検証データのみ"
}

variable "enable_schedule" {
  type        = bool
  default     = true
  description = "Cloud Scheduler による定期実行を作るか。production は true、staging は手動起動のため false (ADR-0005)"
}

variable "pipeline_uploader" {
  type        = string
  default     = ""
  description = "パッケージをアップロードする追加プリンシパル (例: 手元の user アカウント user:me@example.com)。空なら付与しない。Cloud Run job の SA には常に objectAdmin を付ける"
}

variable "pipeline_image" {
  type        = string
  default     = ""
  description = "Cloud Run job が実行するパイプラインイメージ (Artifact Registry の ref、例: asia-northeast1-docker.pkg.dev/<proj>/tendenko/pipeline:latest)。空ならジョブは作らない (イメージ push 後に設定)"
}

variable "pipeline_schedule" {
  type        = string
  default     = "0 18 * * 0" # 毎週日曜 18:00 UTC (= 月曜 03:00 JST)
  description = "パイプライン実行の cron スケジュール (Cloud Scheduler)"
}

variable "pipeline_cpu" {
  type        = string
  default     = "4"
  description = "Cloud Run job の CPU (osmium の 2 段抽出と tilemaker のため多めに)"
}

variable "pipeline_memory" {
  type        = string
  default     = "16Gi"
  description = "Cloud Run job のメモリ (全国 pbf の osmium 抽出は memory 律速。ADR-0003 の OOM 教訓を踏まえ大きめ)"
}

variable "pipeline_task_timeout" {
  type        = string
  default     = "86400s"
  description = "Cloud Run job のタスクタイムアウト (初回全国 run は DEM 取得律速で約 2.6 時間、ADR-0003)"
}
