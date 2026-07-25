output "packages_bucket_url" {
  value       = "gs://${google_storage_bucket.packages.name}"
  description = "build-package -upload に渡す gs:// URL (ADR-0004)"
}

output "packages_public_base_url" {
  value       = "https://storage.googleapis.com/${google_storage_bucket.packages.name}"
  description = "アプリの PackageFetcher が manifest/パッケージを取得する公開 HTTPS ベース URL (末尾に /manifest.json, /packages/region-<mesh>.sqlite)"
}
