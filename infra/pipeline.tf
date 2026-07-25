# データパイプラインの本番実行基盤 (ADR-0001 Stage 1: Cloud Run jobs + Cloud Scheduler)。
#
# パイプラインイメージ (リポジトリ直下の Dockerfile、flake.nix 由来) を Cloud Run job として
# 定期実行し、全国の地域パッケージ (region.sqlite + tiles.mbtiles) を生成して配信バケットへ
# アップロードする (ADR-0003/0004)。入力データ (pbf/GeoJSON/DEM) はデータバケットから読む。
#
# 実行データの GCS 配置 (要手動投入、gitignore 対象のローカルデータをアップロードする):
#   gs://<data_bucket>/japan-latest.osm.pbf
#   gs://<data_bucket>/inundation-japan.geojson
#   gs://<data_bucket>/shelters-japan.geojson
#   gs://<data_bucket>/dem-cache/...           (実行のたびに書き込まれ永続する)

# --- 必要な API ---
resource "google_project_service" "required" {
  for_each = toset([
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- 入力データバケット (非公開) ---
resource "google_storage_bucket" "data" {
  name                        = var.data_bucket_name
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
}

# --- イメージ置き場 (Artifact Registry) ---
resource "google_artifact_registry_repository" "pipeline" {
  location      = var.region
  repository_id = "tendenko"
  format        = "DOCKER"
  project       = var.project_id
  description   = "tendenko パイプラインイメージ"
  depends_on    = [google_project_service.required]
}

# --- パイプライン実行 SA ---
resource "google_service_account" "pipeline" {
  account_id   = "tendenko-pipeline"
  display_name = "tendenko データパイプライン (Cloud Run job)"
  project      = var.project_id
}

# 生成パッケージのアップロード先 (配信バケット) への書き込み。
resource "google_storage_bucket_iam_member" "pipeline_packages" {
  bucket = google_storage_bucket.packages.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.pipeline.email}"
}

# 入力データバケットの読み書き (DEM キャッシュは実行のたびに書き込むため objectAdmin)。
resource "google_storage_bucket_iam_member" "pipeline_data" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.pipeline.email}"
}

# --- Cloud Run job (イメージ未指定なら作らない) ---
resource "google_cloud_run_v2_job" "pipeline" {
  count               = var.pipeline_image == "" ? 0 : 1
  name                = "tendenko-pipeline"
  location            = var.region
  project             = var.project_id
  deletion_protection = false
  depends_on          = [google_project_service.required]

  template {
    task_count = 1
    template {
      service_account = google_service_account.pipeline.email
      timeout         = var.pipeline_task_timeout
      max_retries     = 1

      containers {
        image = var.pipeline_image
        # ENTRYPOINT が build-package なので args のみ渡す (ADR-0003/0004)。
        args = [
          "-pbf", "/data/japan-latest.osm.pbf",
          "-out", "/tmp/out",
          "-tiles",
          "-inundation", "/data/inundation-japan.geojson",
          "-shelters", "/data/shelters-japan.geojson",
          "-dem-cache", "/data/dem-cache",
          "-upload", "gs://${google_storage_bucket.packages.name}",
        ]
        resources {
          limits = {
            cpu    = var.pipeline_cpu
            memory = var.pipeline_memory
          }
        }
        volume_mounts {
          name       = "data"
          mount_path = "/data"
        }
      }

      # 入力データ + DEM キャッシュを gcsfuse でマウントする。
      # 注意: 2.3GB pbf の osmium 読み込みを gcsfuse 越しに行うと遅い可能性がある。
      # 実測で問題なら、起動時に pbf をローカル (/tmp、メモリ) へコピーする方式へ切り替える。
      volumes {
        name = "data"
        gcs {
          bucket    = google_storage_bucket.data.name
          read_only = false
        }
      }
    }
  }
}

# --- Cloud Scheduler で定期実行 ---
resource "google_service_account" "scheduler" {
  account_id   = "tendenko-scheduler"
  display_name = "tendenko パイプライン起動 (Cloud Scheduler)"
  project      = var.project_id
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  count    = var.pipeline_image == "" ? 0 : 1
  name     = google_cloud_run_v2_job.pipeline[0].name
  location = var.region
  project  = var.project_id
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "pipeline" {
  count     = var.pipeline_image == "" ? 0 : 1
  name      = "tendenko-pipeline"
  project   = var.project_id
  region    = var.region
  schedule  = var.pipeline_schedule
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.pipeline[0].name}:run"
    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }
  depends_on = [google_project_service.required]
}
