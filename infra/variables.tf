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

variable "pipeline_uploader" {
  type        = string
  default     = ""
  description = "パッケージをアップロードするプリンシパル (例: serviceAccount:pipeline@<project>.iam.gserviceaccount.com)。空なら IAM を付与しない (ローカルの自分の権限で上げる想定)"
}
