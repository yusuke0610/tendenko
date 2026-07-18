// build-package は OSM・浸水想定ポリゴン・指定緊急避難場所・DEM から
// オフライン用の地域パッケージを生成する。日次〜週次バッチ。
// 分割単位は 2 次メッシュ (沿岸のみ)、出力は region-<meshcode>.sqlite + tiles-<meshcode>.mbtiles (ADR-0003)。
// NFR-04: 1 地域パッケージ < 150MB / 同梱最小データセット < 50MB。
//
// 現状は垂直スライス: メッシュ切り出し済みの .osm (XML) から region.sqlite を生成する。
// 使い方:
//
//	osmium extract -b <bbox> tohoku.pbf -o mesh.osm
//	go run ./cmd/build-package -mesh 584177 -osm mesh.osm -out out/
//
// TODO:
//   - 対象メッシュ列挙 (浸水想定区域と交差 or 海岸線バッファ内の 2 次メッシュ) と osmium 呼び出しの内製化
//   - 浸水想定区域 (国土数値情報 A40) の交差判定 → FlagInundation 付与
//   - 指定緊急避難場所 (国土地理院) → shelters テーブル
//   - tilemaker で MBTiles 生成
//   - manifest (JSON) 生成 → GCS アップロード (バージョン・ハッシュ・生成日時で差分 DL を支える)
package main

import (
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"time"

	"github.com/yusuke0610/tendenko/pipeline/internal/dem"
	"github.com/yusuke0610/tendenko/pipeline/internal/graph"
	"github.com/yusuke0610/tendenko/pipeline/internal/mesh"
	"github.com/yusuke0610/tendenko/pipeline/internal/osmxml"
	"github.com/yusuke0610/tendenko/pipeline/internal/pkgwriter"
)

func main() {
	var (
		meshCode = flag.String("mesh", "", "2 次メッシュコード (例: 584177)")
		osmPath  = flag.String("osm", "", "メッシュ切り出し済み .osm (XML) のパス")
		outDir   = flag.String("out", "out", "出力ディレクトリ")
		demCache = flag.String("dem-cache", "data/dem-cache", "地理院標高タイルのキャッシュディレクトリ")
		skipDEM  = flag.Bool("skip-dem", false, "標高取得をスキップする (オフライン動作確認用)")
	)
	flag.Parse()
	if *meshCode == "" || *osmPath == "" {
		flag.Usage()
		os.Exit(2)
	}
	if _, err := mesh.ParseSecondary(*meshCode); err != nil {
		log.Fatal(err)
	}

	start := time.Now()
	stage := func(name string, from time.Time) time.Time {
		now := time.Now()
		fmt.Printf("%-12s %8.2fs\n", name, now.Sub(from).Seconds())
		return now
	}

	f, err := os.Open(*osmPath)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	allNodes, ways, err := osmxml.Parse(f, graph.Walkable)
	if err != nil {
		log.Fatal(err)
	}
	t := stage("parse", start)
	fmt.Printf("  nodes(all)=%d walkable-ways=%d\n", len(allNodes), len(ways))

	nodes, edges := graph.Build(allNodes, ways)
	t = stage("graph", t)
	fmt.Printf("  nodes(used)=%d edges=%d\n", len(nodes), len(edges))

	elev := map[int64]float64{} // 値なし = NaN 扱い
	if !*skipDEM {
		client := dem.NewClient(*demCache)
		missing := 0
		for id, n := range nodes {
			v, ok, err := client.Elevation(n.Lat, n.Lon)
			if err != nil {
				log.Fatal(err)
			}
			if ok {
				elev[id] = v
			} else {
				missing++
			}
		}
		t = stage("dem", t)
		fmt.Printf("  elevations=%d missing=%d\n", len(elev), missing)
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

	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		log.Fatal(err)
	}
	outPath := filepath.Join(*outDir, "region-"+*meshCode+".sqlite")
	os.Remove(outPath)
	if err := pkgwriter.Write(outPath, *meshCode, "OSM (Geofabrik) + 地理院標高タイル DEM10B", nodeRows, edgeRows); err != nil {
		log.Fatal(err)
	}
	t = stage("sqlite", t)
	stage("total", start)

	info, err := os.Stat(outPath)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("\n%s  %.1f MB\n", outPath, float64(info.Size())/1024/1024)
}
