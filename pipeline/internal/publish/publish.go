// Package publish は生成済みの地域パッケージと manifest を GCS にアップロードする (ADR-0004)。
//
// レイアウト:
//
//	<bucket>/<prefix>/manifest.json
//	<bucket>/<prefix>/packages/region-<mesh>.sqlite
//	<bucket>/<prefix>/packages/tiles-<mesh>.mbtiles
//
// 認証は ADC (Cloud Run jobs の Workload Identity / ローカルの gcloud auth) に委ねる。
// 既存オブジェクトと CRC32C が一致するファイルはスキップする (gsutil rsync 相当の差分)。
package publish

import (
	"context"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
	"strings"

	"cloud.google.com/go/storage"
)

var crcTable = crc32.MakeTable(crc32.Castagnoli)

// ObjectKey は出力ファイル名を GCS のオブジェクトキー (prefix なし) に写像する。
// manifest.json はルート、パッケージファイルは packages/ 配下に置く。
func ObjectKey(fileName string) string {
	if fileName == "manifest.json" {
		return "manifest.json"
	}
	return "packages/" + fileName
}

// Uploadable はアップロード対象のファイル名か判定する (manifest とパッケージのみ)。
func Uploadable(fileName string) bool {
	switch {
	case fileName == "manifest.json":
		return true
	case strings.HasPrefix(fileName, "region-") && strings.HasSuffix(fileName, ".sqlite"):
		return true
	case strings.HasPrefix(fileName, "tiles-") && strings.HasSuffix(fileName, ".mbtiles"):
		return true
	default:
		return false
	}
}

// ParseGSURL は gs://bucket/prefix を分解する。prefix は省略可。
func ParseGSURL(u string) (bucket, prefix string, err error) {
	rest, ok := strings.CutPrefix(u, "gs://")
	if !ok {
		return "", "", fmt.Errorf("publish: %q は gs://bucket[/prefix] 形式ではない", u)
	}
	bucket, prefix, _ = strings.Cut(rest, "/")
	if bucket == "" {
		return "", "", fmt.Errorf("publish: バケット名が空 (%q)", u)
	}
	return bucket, strings.Trim(prefix, "/"), nil
}

// Upload は outDir のアップロード対象ファイルを gsURL (gs://bucket[/prefix]) に送る。
// manifest.json はパッケージ本体をすべて送り終えてから最後に上げる — クライアントが
// 未アップロードのパッケージを参照する manifest を見ないようにするため。
func Upload(ctx context.Context, gsURL, outDir string) error {
	bucket, prefix, err := ParseGSURL(gsURL)
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(outDir)
	if err != nil {
		return err
	}

	client, err := storage.NewClient(ctx)
	if err != nil {
		return fmt.Errorf("publish: GCS クライアント生成: %w", err)
	}
	defer func() { _ = client.Close() }()
	bkt := client.Bucket(bucket)

	uploaded, skipped, hasManifest := 0, 0, false
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !Uploadable(name) {
			continue
		}
		if name == "manifest.json" {
			hasManifest = true
			continue // 最後に回す
		}
		didUpload, err := uploadIfChanged(ctx, bkt, filepath.Join(outDir, name), keyWithPrefix(prefix, name))
		if err != nil {
			return fmt.Errorf("publish: %s: %w", name, err)
		}
		if didUpload {
			uploaded++
		} else {
			skipped++
		}
	}
	if hasManifest {
		if _, err := uploadIfChanged(ctx, bkt, filepath.Join(outDir, "manifest.json"),
			keyWithPrefix(prefix, "manifest.json")); err != nil {
			return fmt.Errorf("publish: manifest.json: %w", err)
		}
	}
	fmt.Printf("publish: uploaded=%d skipped(unchanged)=%d → gs://%s/%s\n", uploaded, skipped, bucket, prefix)
	return nil
}

func keyWithPrefix(prefix, name string) string {
	key := ObjectKey(name)
	if prefix == "" {
		return key
	}
	return prefix + "/" + key
}

// uploadIfChanged はローカルの CRC32C が既存オブジェクトと一致すればスキップする。
func uploadIfChanged(ctx context.Context, bkt *storage.BucketHandle, path, key string) (bool, error) {
	local, err := localCRC32C(path)
	if err != nil {
		return false, err
	}
	obj := bkt.Object(key)
	if attrs, err := obj.Attrs(ctx); err == nil {
		if attrs.CRC32C == local {
			return false, nil // 中身が同じ
		}
	} else if !errors.Is(err, storage.ErrObjectNotExist) {
		return false, err
	}

	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer func() { _ = f.Close() }()
	w := obj.NewWriter(ctx)
	if _, err := io.Copy(w, f); err != nil {
		_ = w.Close()
		return false, err
	}
	if err := w.Close(); err != nil {
		return false, err
	}
	return true, nil
}

func localCRC32C(path string) (uint32, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer func() { _ = f.Close() }()
	h := crc32.New(crcTable)
	if _, err := io.Copy(h, f); err != nil {
		return 0, err
	}
	return h.Sum32(), nil
}
