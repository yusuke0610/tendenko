// build-package は OSM・DEM から地域パッケージ (region.sqlite) を生成する。
// 分割単位は 2 次メッシュ、対象は沿岸メッシュのみ (ADR-0003)。
//
// 一括モード (全国 pbf でも地方抽出版でも同じ):
//
//	go run ./cmd/build-package -pbf data/japan-latest.osm.pbf -out out
//
// OSM の海岸線 (natural=coastline) を含むメッシュ + 隣接 -buffer リングを列挙し、
// osmium で一括切り出し → 各メッシュの region.sqlite と manifest.json を生成する。
// osmium が PATH に必要 (nix develop 内で実行する)。
//
// 単一モード (デバッグ用):
//
//	osmium extract -b <bbox> data/tohoku-latest.osm.pbf -o data/mesh-584177.osm
//	go run ./cmd/build-package -mesh 584177 -osm data/mesh-584177.osm -out out
//
// TODO:
//   - 浸水想定区域 (国土数値情報 A40) の交差判定 → FlagInundation 付与
//   - 指定緊急避難場所 (国土地理院) → shelters テーブル
//   - tilemaker で MBTiles 生成 (macOS/arm64 の nixpkgs ビルドがクラッシュするため Linux で)
//   - GCS アップロード
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"time"

	"github.com/yusuke0610/tendenko/pipeline/internal/dem"
	"github.com/yusuke0610/tendenko/pipeline/internal/graph"
	"github.com/yusuke0610/tendenko/pipeline/internal/mesh"
	"github.com/yusuke0610/tendenko/pipeline/internal/osmxml"
	"github.com/yusuke0610/tendenko/pipeline/internal/pkgwriter"
)

const sourceNote = "OSM (Geofabrik) + 地理院標高タイル DEM10B"

func main() {
	var (
		pbfPath  = flag.String("pbf", "", "一括モード: OSM pbf (全国版または地方抽出版)")
		meshCode = flag.String("mesh", "", "単一モード: 2 次メッシュコード (例: 584177)")
		osmPath  = flag.String("osm", "", "単一モード: メッシュ切り出し済み .osm (XML)")
		outDir   = flag.String("out", "out", "出力ディレクトリ")
		demCache = flag.String("dem-cache", "data/dem-cache", "地理院標高タイルのキャッシュディレクトリ")
		skipDEM  = flag.Bool("skip-dem", false, "標高取得をスキップする (オフライン動作確認用)")
		buffer   = flag.Int("buffer", 1, "一括モード: 海岸線メッシュに加える隣接リング数 (1 ≈ 10km)")
	)
	flag.Parse()
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		log.Fatal(err)
	}

	switch {
	case *pbfPath != "":
		if err := runBatch(*pbfPath, *outDir, *demCache, *buffer, *skipDEM); err != nil {
			log.Fatal(err)
		}
	case *meshCode != "" && *osmPath != "":
		if _, err := mesh.ParseSecondary(*meshCode); err != nil {
			log.Fatal(err)
		}
		r, err := buildOne(*meshCode, *osmPath, *outDir, *demCache, *skipDEM, true)
		if err != nil {
			log.Fatal(err)
		}
		fmt.Printf("\n%s  %.1f MB\n", filepath.Join(*outDir, r.File), float64(r.Bytes)/1024/1024)
	default:
		flag.Usage()
		os.Exit(2)
	}
}

// ---- 一括モード ----

type manifestEntry struct {
	Mesh   string `json:"mesh"`
	File   string `json:"file"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256"`
	Nodes  int    `json:"nodes"`
	Edges  int    `json:"edges"`
}

type manifest struct {
	SchemaVersion int             `json:"schema_version"`
	GeneratedAt   string          `json:"generated_at"`
	Source        string          `json:"source"`
	Packages      []manifestEntry `json:"packages"`
}

func runBatch(pbfPath, outDir, demCache string, buffer int, skipDEM bool) error {
	start := time.Now()
	tmp, err := os.MkdirTemp("", "tendenko-build-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(tmp) }()

	// 1. 海岸線を含むメッシュを列挙し、隣接リングでバッファする
	coastOSM := filepath.Join(tmp, "coast.osm")
	if err := osmium("tags-filter", pbfPath, "w/natural=coastline", "-o", coastOSM, "--overwrite"); err != nil {
		return err
	}
	coastal, err := coastalMeshes(coastOSM)
	if err != nil {
		return err
	}
	target, err := mesh.Expand(coastal, buffer)
	if err != nil {
		return err
	}
	codes := make([]string, 0, len(target))
	for c := range target {
		codes = append(codes, c)
	}
	sort.Strings(codes)
	fmt.Printf("coastline meshes=%d → +buffer(%d)=%d  (%.1fs)\n",
		len(coastal), buffer, len(codes), time.Since(start).Seconds())

	// 2. osmium で一括切り出し (1 パスあたり 50 メッシュ)
	extractStart := time.Now()
	if err := extractAll(pbfPath, codes, tmp); err != nil {
		return err
	}
	fmt.Printf("extract done (%.1fs)\n", time.Since(extractStart).Seconds())

	// 3. 各メッシュを生成。歩行可能な道路が無いメッシュ (海上など) はスキップ
	var entries []manifestEntry
	skipped := 0
	for i, code := range codes {
		r, err := buildOne(code, filepath.Join(tmp, "mesh-"+code+".osm"), outDir, demCache, skipDEM, false)
		if err != nil {
			return fmt.Errorf("mesh %s: %w", code, err)
		}
		if r == nil {
			skipped++
			continue
		}
		entries = append(entries, *r)
		fmt.Printf("[%d/%d] %s nodes=%d edges=%d %.1fMB\n",
			i+1, len(codes), code, r.Nodes, r.Edges, float64(r.Bytes)/1024/1024)
	}

	// 4. manifest.json (FR-06 の差分 DL 用: バージョン・ハッシュ・生成日時)
	m := manifest{
		SchemaVersion: 1,
		GeneratedAt:   time.Now().UTC().Format(time.RFC3339),
		Source:        sourceNote,
		Packages:      entries,
	}
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(outDir, "manifest.json"), b, 0o644); err != nil {
		return err
	}

	var total int64
	for _, e := range entries {
		total += e.Bytes
	}
	fmt.Printf("\npackages=%d skipped(empty)=%d total=%.1fMB elapsed=%.0fs\n",
		len(entries), skipped, float64(total)/1024/1024, time.Since(start).Seconds())
	return nil
}

// coastalMeshes は natural=coastline のノードが属する 2 次メッシュを列挙する。
func coastalMeshes(coastOSM string) (map[string]bool, error) {
	f, err := os.Open(coastOSM)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	nodes, _, err := osmxml.Parse(f, func(map[string]string) bool { return false })
	if err != nil {
		return nil, err
	}
	set := make(map[string]bool)
	for _, n := range nodes {
		set[mesh.SecondaryCode(n.Lat, n.Lon)] = true
	}
	return set, nil
}

// extractAll は 2 段階で切り出す。全国 pbf (2.3GB) を 2 次メッシュごとに直接切り出すと
// パス数 × 全読みで遅く、抽出数を増やすとメモリで死ぬ (全国 4,481 メッシュで実測 OOM kill)。
// そこで親の 1 次メッシュ (80km 四方、全国の沿岸で 100 個規模) 単位でまず切り出し、
// 小さくなった各 1 次メッシュ pbf から配下の 2 次メッシュを展開する。
func extractAll(pbfPath string, codes []string, dir string) error {
	byParent := map[string][]string{}
	for _, c := range codes {
		byParent[c[:4]] = append(byParent[c[:4]], c)
	}
	parents := make([]string, 0, len(byParent))
	for p := range byParent {
		parents = append(parents, p)
	}
	sort.Strings(parents)

	// レベル 1: 1 次メッシュを 20 個ずつ切り出す (pbf 出力)
	const parentBatch = 20
	passes := (len(parents) + parentBatch - 1) / parentBatch
	for i := 0; i < len(parents); i += parentBatch {
		batch := parents[i:min(i+parentBatch, len(parents))]
		var extracts []extractCfg
		for _, p := range batch {
			bbox, err := mesh.ParsePrimary(p)
			if err != nil {
				return err
			}
			extracts = append(extracts, extractCfg{
				Output: "parent-" + p + ".osm.pbf",
				BBox:   [4]float64{bbox.MinLon, bbox.MinLat, bbox.MaxLon, bbox.MaxLat},
			})
		}
		start := time.Now()
		if err := osmiumExtract(pbfPath, dir, extracts); err != nil {
			return err
		}
		fmt.Printf("extract L1 pass %d/%d (%d parents) %.0fs\n",
			i/parentBatch+1, passes, len(batch), time.Since(start).Seconds())
	}

	// レベル 2: 各 1 次メッシュ pbf から配下の 2 次メッシュを展開 (XML 出力)
	for _, p := range parents {
		parentPBF := filepath.Join(dir, "parent-"+p+".osm.pbf")
		var extracts []extractCfg
		for _, code := range byParent[p] {
			bbox, err := mesh.ParseSecondary(code)
			if err != nil {
				return err
			}
			extracts = append(extracts, extractCfg{
				Output: "mesh-" + code + ".osm",
				BBox:   [4]float64{bbox.MinLon, bbox.MinLat, bbox.MaxLon, bbox.MaxLat},
			})
		}
		if err := osmiumExtract(parentPBF, dir, extracts); err != nil {
			return err
		}
		_ = os.Remove(parentPBF) // ディスク節約
	}
	return nil
}

type extractCfg struct {
	Output string     `json:"output"`
	BBox   [4]float64 `json:"bbox"`
}

func osmiumExtract(inputPath, dir string, extracts []extractCfg) error {
	cfg := struct {
		Directory string       `json:"directory"`
		Extracts  []extractCfg `json:"extracts"`
	}{Directory: dir, Extracts: extracts}
	b, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	cfgPath := filepath.Join(dir, "extracts.json")
	if err := os.WriteFile(cfgPath, b, 0o644); err != nil {
		return err
	}
	return osmium("extract", "-c", cfgPath, inputPath, "--overwrite")
}

func osmium(args ...string) error {
	cmd := exec.Command("osmium", args...)
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("osmium %v: %w", args[:1], err)
	}
	return nil
}

// ---- 単一メッシュの生成 ----

// buildOne は 1 メッシュの region.sqlite を生成する。歩行可能な道路が無ければ nil を返す。
func buildOne(meshCode, osmPath, outDir, demCache string, skipDEM, verbose bool) (*manifestEntry, error) {
	start := time.Now()
	stage := func(name string, from time.Time) time.Time {
		now := time.Now()
		if verbose {
			fmt.Printf("%-12s %8.2fs\n", name, now.Sub(from).Seconds())
		}
		return now
	}

	f, err := os.Open(osmPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	allNodes, ways, err := osmxml.Parse(f, graph.Walkable)
	if err != nil {
		return nil, err
	}
	t := stage("parse", start)

	nodes, edges := graph.Build(allNodes, ways)
	t = stage("graph", t)
	if len(edges) == 0 {
		return nil, nil
	}

	elev := map[int64]float64{}
	if !skipDEM {
		// クライアントをメッシュごとに作り直してメモリ上のタイル保持を抑える
		// (ディスクキャッシュは demCache で共有され、隣接メッシュの再取得はネットワークに出ない)
		client := dem.NewClient(demCache)
		for id, n := range nodes {
			v, ok, err := client.Elevation(n.Lat, n.Lon)
			if err != nil {
				return nil, err
			}
			if ok {
				elev[id] = v
			}
		}
		t = stage("dem", t)
	}

	nodeRows := make([]pkgwriter.NodeRow, 0, len(nodes))
	for id, n := range nodes {
		e, ok := elev[id]
		if !ok {
			e = math.NaN()
		}
		nodeRows = append(nodeRows, pkgwriter.NodeRow{ID: id, Lat: n.Lat, Lon: n.Lon, ElevM: e})
	}
	edgeRows := make([]pkgwriter.EdgeRow, 0, len(edges))
	for _, e := range edges {
		grade := 0.0
		ea, okA := elev[e.From]
		eb, okB := elev[e.To]
		if okA && okB && e.LengthM > 0 {
			grade = (eb - ea) / e.LengthM
		}
		edgeRows = append(edgeRows, pkgwriter.EdgeRow{
			From: e.From, To: e.To,
			LengthM: e.LengthM, Grade: grade, BearingDeg: e.BearingDeg, Flags: e.Flags,
		})
	}

	file := "region-" + meshCode + ".sqlite"
	outPath := filepath.Join(outDir, file)
	_ = os.Remove(outPath) // pkgwriter.Write は既存ファイルに追記できないため消してから作る
	if err := pkgwriter.Write(outPath, meshCode, sourceNote, nodeRows, edgeRows); err != nil {
		return nil, err
	}
	stage("sqlite", t)
	stage("total", start)

	info, err := os.Stat(outPath)
	if err != nil {
		return nil, err
	}
	sum, err := fileSHA256(outPath)
	if err != nil {
		return nil, err
	}
	return &manifestEntry{
		Mesh: meshCode, File: file, Bytes: info.Size(), SHA256: sum,
		Nodes: len(nodeRows), Edges: len(edgeRows),
	}, nil
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
