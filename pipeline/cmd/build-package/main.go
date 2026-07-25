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
// 浸水想定区域 (-inundation) と避難場所 (-shelters) は、正規化 GeoJSON を受け取る
// (internal/inundation, internal/shelterdata のドキュメント参照)。実データ (国土数値情報
// A40・国土地理院) の取得・正規化は pipeline/scripts/normalize-a40.sh /
// normalize-shelters.sh を参照 (取得元 URL・ライセンスは ADR-0003 と docs/licenses.md)。
//
// 生成後に GCS へ上げる (ADR-0004):
//
//	go run ./cmd/build-package -pbf data/japan-latest.osm.pbf -tiles -out out -upload gs://<bucket>
//
// 認証は ADC (Cloud Run jobs の Workload Identity / ローカルの gcloud auth application-default login)。
package main

import (
	"context"
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
	"github.com/yusuke0610/tendenko/pipeline/internal/inundation"
	"github.com/yusuke0610/tendenko/pipeline/internal/mesh"
	"github.com/yusuke0610/tendenko/pipeline/internal/osmxml"
	"github.com/yusuke0610/tendenko/pipeline/internal/pkgwriter"
	"github.com/yusuke0610/tendenko/pipeline/internal/publish"
	"github.com/yusuke0610/tendenko/pipeline/internal/shelterdata"
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
		inunPath = flag.String("inundation", "", "浸水想定区域の正規化 GeoJSON (省略時は FlagInundation を付与しない)")
		shelPath = flag.String("shelters", "", "避難場所の正規化 GeoJSON (省略時は shelters テーブルを空にする)")
		tiles    = flag.Bool("tiles", false, "MBTiles (tilemaker) も生成する。macOS/arm64 では tilemaker がクラッシュするため Linux 専用 (ADR-0003)")
		upload   = flag.String("upload", "", "一括モード: 生成後に GCS へアップロードする (gs://bucket[/prefix]、ADR-0004)。認証は ADC")
	)
	flag.Parse()
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		log.Fatal(err)
	}

	if *tiles {
		if _, err := exec.LookPath("tilemaker"); err != nil {
			log.Fatal("-tiles が指定されましたが tilemaker が PATH にありません (nix develop 内か確認してください)")
		}
	}

	var inunIdx *inundation.Index
	if *inunPath != "" {
		polys, err := inundation.Load(*inunPath)
		if err != nil {
			log.Fatal(err)
		}
		inunIdx = inundation.NewIndex(polys)
	}
	var allShelters []shelterdata.Shelter
	if *shelPath != "" {
		s, err := shelterdata.Load(*shelPath)
		if err != nil {
			log.Fatal(err)
		}
		allShelters = s
	}

	switch {
	case *pbfPath != "":
		if err := runBatch(*pbfPath, *outDir, *demCache, *buffer, *skipDEM, inunIdx, allShelters, *tiles); err != nil {
			log.Fatal(err)
		}
		if *upload != "" {
			if err := publish.Upload(context.Background(), *upload, *outDir); err != nil {
				log.Fatal(err)
			}
		}
	case *meshCode != "" && *osmPath != "":
		if _, err := mesh.ParseSecondary(*meshCode); err != nil {
			log.Fatal(err)
		}
		r, err := buildOne(*meshCode, *osmPath, "", *outDir, *demCache, *skipDEM, true, inunIdx, allShelters)
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
	Mesh        string `json:"mesh"`
	File        string `json:"file"`
	Bytes       int64  `json:"bytes"`
	SHA256      string `json:"sha256"`
	Nodes       int    `json:"nodes"`
	Edges       int    `json:"edges"`
	Shelters    int    `json:"shelters"`
	TilesFile   string `json:"tiles_file,omitempty"`
	TilesBytes  int64  `json:"tiles_bytes,omitempty"`
	TilesSHA256 string `json:"tiles_sha256,omitempty"`
}

type manifest struct {
	SchemaVersion int             `json:"schema_version"`
	GeneratedAt   string          `json:"generated_at"`
	Source        string          `json:"source"`
	Packages      []manifestEntry `json:"packages"`
}

func runBatch(pbfPath, outDir, demCache string, buffer int, skipDEM bool,
	inunIdx *inundation.Index, allShelters []shelterdata.Shelter, tiles bool) error {
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
	if err := extractAll(pbfPath, codes, tmp, tiles); err != nil {
		return err
	}
	fmt.Printf("extract done (%.1fs)\n", time.Since(extractStart).Seconds())

	// 3. 各メッシュを生成。歩行可能な道路が無いメッシュ (海上など) はスキップ
	var entries []manifestEntry
	skipped := 0
	for i, code := range codes {
		meshPBF := ""
		if tiles {
			meshPBF = filepath.Join(tmp, "mesh-"+code+".osm.pbf")
		}
		r, err := buildOne(code, filepath.Join(tmp, "mesh-"+code+".osm"), meshPBF, outDir, demCache, skipDEM, false,
			inunIdx, allShelters)
		if err != nil {
			return fmt.Errorf("mesh %s: %w", code, err)
		}
		if r == nil {
			skipped++
			continue
		}
		entries = append(entries, *r)
		tilesNote := ""
		if r.TilesFile != "" {
			tilesNote = fmt.Sprintf(" tiles=%.1fMB", float64(r.TilesBytes)/1024/1024)
		}
		fmt.Printf("[%d/%d] %s nodes=%d edges=%d %.1fMB%s\n",
			i+1, len(codes), code, r.Nodes, r.Edges, float64(r.Bytes)/1024/1024, tilesNote)
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

	var total, totalTiles int64
	for _, e := range entries {
		total += e.Bytes
		totalTiles += e.TilesBytes
	}
	tilesNote := ""
	if tiles {
		tilesNote = fmt.Sprintf(" tiles_total=%.1fMB", float64(totalTiles)/1024/1024)
	}
	fmt.Printf("\npackages=%d skipped(empty)=%d total=%.1fMB%s elapsed=%.0fs\n",
		len(entries), skipped, float64(total)/1024/1024, tilesNote, time.Since(start).Seconds())
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
func extractAll(pbfPath string, codes []string, dir string, withPBF bool) error {
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

	// レベル 2: 各 1 次メッシュ pbf から配下の 2 次メッシュを展開 (XML 出力。
	// withPBF なら tilemaker 用に同じ範囲の pbf も併せて出力する。単一パスで両方
	// 書き出せるため osmium の読み込みコストは増えない)
	for _, p := range parents {
		parentPBF := filepath.Join(dir, "parent-"+p+".osm.pbf")
		var extracts []extractCfg
		for _, code := range byParent[p] {
			bbox, err := mesh.ParseSecondary(code)
			if err != nil {
				return err
			}
			bboxArr := [4]float64{bbox.MinLon, bbox.MinLat, bbox.MaxLon, bbox.MaxLat}
			extracts = append(extracts, extractCfg{Output: "mesh-" + code + ".osm", BBox: bboxArr})
			if withPBF {
				extracts = append(extracts, extractCfg{Output: "mesh-" + code + ".osm.pbf", BBox: bboxArr})
			}
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

// tilemakerShareDir は tilemaker に同梱される config/process ファイルのディレクトリを探す
// (nix パッケージのレイアウト: <bin>/../share/tilemaker)。
func tilemakerShareDir() (string, error) {
	bin, err := exec.LookPath("tilemaker")
	if err != nil {
		return "", err
	}
	dir := filepath.Join(filepath.Dir(bin), "..", "share", "tilemaker")
	if _, err := os.Stat(dir); err != nil {
		return "", fmt.Errorf("tilemaker: share dir not found at %s: %w", dir, err)
	}
	return dir, nil
}

// tilemakerRun は 1 メッシュ分の MBTiles を生成する (OpenMapTiles スキーマ)。
func tilemakerRun(pbfPath, bboxCSV, outPath string) error {
	share, err := tilemakerShareDir()
	if err != nil {
		return err
	}
	cmd := exec.Command("tilemaker",
		"--input", pbfPath,
		"--output", outPath,
		"--bbox", bboxCSV,
		"--config", filepath.Join(share, "config-openmaptiles.json"),
		"--process", filepath.Join(share, "process-openmaptiles.lua"),
	)
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("tilemaker %s: %w", pbfPath, err)
	}
	return nil
}

// ---- 単一メッシュの生成 ----

// buildOne は 1 メッシュの region.sqlite を生成する。歩行可能な道路が無ければ nil を返す。
// inunIdx が nil なら浸水フラグを付与しない。allShelters は全域分の避難場所を渡し、
// メッシュ範囲内のものだけをここでフィルタする (呼び出し側では読み込みを 1 回に留める)。
// meshPBFPath が空でなければ、同じ範囲の MBTiles も生成する (tilemaker が必要、ADR-0003)。
func buildOne(meshCode, osmPath, meshPBFPath, outDir, demCache string, skipDEM, verbose bool,
	inunIdx *inundation.Index, allShelters []shelterdata.Shelter) (*manifestEntry, error) {
	start := time.Now()
	stage := func(name string, from time.Time) time.Time {
		now := time.Now()
		if verbose {
			fmt.Printf("%-12s %8.2fs\n", name, now.Sub(from).Seconds())
		}
		return now
	}

	bbox, err := mesh.ParseSecondary(meshCode)
	if err != nil {
		return nil, err
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

	// 浸水想定区域との交差判定 (FR-12)。inunIdx が nil (実データ未指定) ならスキップ。
	// 全国規模の Index (数十万ポリゴン) をメッシュ範囲で Subset してから使うことで、
	// エッジごとの bbox 走査を大幅に減らす (実測: 釜石メッシュで 3.5 秒 → 数十 ms)。
	if inunIdx != nil {
		meshIdx := inunIdx.Subset(bbox.MinLon, bbox.MinLat, bbox.MaxLon, bbox.MaxLat)
		for i := range edges {
			a, b := nodes[edges[i].From], nodes[edges[i].To]
			if meshIdx.Intersects(a.Lat, a.Lon, b.Lat, b.Lon) {
				edges[i].Flags |= graph.FlagInundation
			}
		}
		t = stage("inundation", t)
	}

	var client *dem.Client
	if !skipDEM {
		// クライアントをメッシュごとに作り直してメモリ上のタイル保持を抑える
		// (ディスクキャッシュは demCache で共有され、隣接メッシュの再取得はネットワークに出ない)
		client = dem.NewClient(demCache)
	}
	elev := map[int64]float64{}
	if client != nil {
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

	shelterRows := make([]pkgwriter.ShelterRow, 0)
	for _, s := range shelterdata.InBBox(allShelters, bbox) {
		elevM := math.NaN()
		if client != nil {
			if v, ok, err := client.Elevation(s.Lat, s.Lon); err != nil {
				return nil, err
			} else if ok {
				elevM = v
			}
		}
		shelterRows = append(shelterRows, pkgwriter.ShelterRow{Name: s.Name, Lat: s.Lat, Lon: s.Lon, ElevM: elevM})
	}

	file := "region-" + meshCode + ".sqlite"
	outPath := filepath.Join(outDir, file)
	_ = os.Remove(outPath) // pkgwriter.Write は既存ファイルに追記できないため消してから作る
	if err := pkgwriter.Write(outPath, meshCode, sourceNote, nodeRows, edgeRows, shelterRows); err != nil {
		return nil, err
	}
	t = stage("sqlite", t)

	info, err := os.Stat(outPath)
	if err != nil {
		return nil, err
	}
	sum, err := fileSHA256(outPath)
	if err != nil {
		return nil, err
	}
	entry := &manifestEntry{
		Mesh: meshCode, File: file, Bytes: info.Size(), SHA256: sum,
		Nodes: len(nodeRows), Edges: len(edgeRows), Shelters: len(shelterRows),
	}

	if meshPBFPath != "" {
		tilesFile := "tiles-" + meshCode + ".mbtiles"
		tilesPath := filepath.Join(outDir, tilesFile)
		bboxCSV := fmt.Sprintf("%g,%g,%g,%g", bbox.MinLon, bbox.MinLat, bbox.MaxLon, bbox.MaxLat)
		if err := tilemakerRun(meshPBFPath, bboxCSV, tilesPath); err != nil {
			return nil, err
		}
		tilesInfo, err := os.Stat(tilesPath)
		if err != nil {
			return nil, err
		}
		tilesSum, err := fileSHA256(tilesPath)
		if err != nil {
			return nil, err
		}
		entry.TilesFile = tilesFile
		entry.TilesBytes = tilesInfo.Size()
		entry.TilesSHA256 = tilesSum
		stage("tiles", t)
	}
	stage("total", start)

	return entry, nil
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
