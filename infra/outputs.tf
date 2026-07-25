output "packages_bucket_url" {
  value       = "gs://${google_storage_bucket.packages.name}"
  description = "build-package -upload に渡す gs:// URL (ADR-0004)"
}

output "packages_public_base_url" {
  value       = "https://storage.googleapis.com/${google_storage_bucket.packages.name}"
  description = "アプリの PackageFetcher が manifest/パッケージを取得する公開 HTTPS ベース URL (末尾に /manifest.json, /packages/region-<mesh>.sqlite)"
}

output "data_bucket_url" {
  value       = "gs://${google_storage_bucket.data.name}"
  description = "パイプライン入力データ (pbf/GeoJSON/DEM) の投入先"
}

output "pipeline_image_repo" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.pipeline.repository_id}"
  description = "パイプラインイメージの push 先 (例: <repo>/pipeline:latest を pipeline_image に設定)"
}
