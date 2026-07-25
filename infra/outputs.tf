output "packages_bucket_url" {
  value       = "gs://${google_storage_bucket.packages.name}"
  description = "build-package -upload に渡す gs:// URL (ADR-0004)"
}
