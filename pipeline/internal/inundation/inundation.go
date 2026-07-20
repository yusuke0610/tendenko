// Package inundation は津波浸水想定区域ポリゴンの読み込みと交差判定を行う (FR-12, ADR-0003)。
//
// 入力は正規化された GeoJSON (Polygon/MultiPolygon の FeatureCollection、座標は
// GeoJSON 標準どおり [lon, lat]) を受け付ける。国土数値情報 A40 (Shapefile) 等の
// 実データはこの形式に変換してから渡す (例: ogr2ogr -f GeoJSON out.geojson A40.shp)。
// 実データの取得元・変換手順は別途 ADR-0003 に追記する (URL は要確認のため未着手)。
package inundation

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
)

// Polygon はリング列。Rings[0] が外周、以降は穴。各点は [lon, lat] (GeoJSON の座標順)。
type Polygon struct {
	Rings [][][2]float64
}

type bbox struct {
	minLon, minLat, maxLon, maxLat float64
}

func (p Polygon) boundingBox() bbox {
	b := bbox{minLon: math.Inf(1), minLat: math.Inf(1), maxLon: math.Inf(-1), maxLat: math.Inf(-1)}
	if len(p.Rings) == 0 {
		return b
	}
	for _, pt := range p.Rings[0] {
		b.minLon = math.Min(b.minLon, pt[0])
		b.maxLon = math.Max(b.maxLon, pt[0])
		b.minLat = math.Min(b.minLat, pt[1])
		b.maxLat = math.Max(b.maxLat, pt[1])
	}
	return b
}

// Contains は点がポリゴン内かを判定する。穴は外周とのレイキャスト結果を
// XOR することで扱う (穴の中の点は外周=true, 穴=true → false になる)。
func (p Polygon) Contains(lat, lon float64) bool {
	inside := false
	for _, ring := range p.Rings {
		if pointInRing(ring, lon, lat) {
			inside = !inside
		}
	}
	return inside
}

// pointInRing は標準的なレイキャスト法 (点から +x 方向への半直線と辺の交差数の偶奇)。
func pointInRing(ring [][2]float64, x, y float64) bool {
	inside := false
	n := len(ring)
	for i, j := 0, n-1; i < n; j, i = i, i+1 {
		xi, yi := ring[i][0], ring[i][1]
		xj, yj := ring[j][0], ring[j][1]
		if (yi > y) != (yj > y) {
			xIntersect := (xj-xi)*(y-yi)/(yj-yi) + xi
			if x < xIntersect {
				inside = !inside
			}
		}
	}
	return inside
}

// Load は GeoJSON FeatureCollection から Polygon/MultiPolygon 形状をすべて読み込む。
// Polygon 以外のジオメトリ (Point 等) は無視する。
func Load(path string) ([]Polygon, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("inundation: %w", err)
	}
	var fc struct {
		Features []struct {
			Geometry struct {
				Type        string          `json:"type"`
				Coordinates json.RawMessage `json:"coordinates"`
			} `json:"geometry"`
		} `json:"features"`
	}
	if err := json.Unmarshal(data, &fc); err != nil {
		return nil, fmt.Errorf("inundation: %s: %w", path, err)
	}

	var polys []Polygon
	for i, f := range fc.Features {
		switch f.Geometry.Type {
		case "Polygon":
			var rings [][][2]float64
			if err := json.Unmarshal(f.Geometry.Coordinates, &rings); err != nil {
				return nil, fmt.Errorf("inundation: feature %d: %w", i, err)
			}
			polys = append(polys, Polygon{Rings: rings})
		case "MultiPolygon":
			var multi [][][][2]float64
			if err := json.Unmarshal(f.Geometry.Coordinates, &multi); err != nil {
				return nil, fmt.Errorf("inundation: feature %d: %w", i, err)
			}
			for _, rings := range multi {
				polys = append(polys, Polygon{Rings: rings})
			}
		}
	}
	return polys, nil
}

// Index はポリゴン集合に対する交差判定を bbox 前置フィルタで高速化する。
type Index struct {
	polys  []Polygon
	bboxes []bbox
}

func NewIndex(polys []Polygon) *Index {
	idx := &Index{polys: polys, bboxes: make([]bbox, len(polys))}
	for i, p := range polys {
		idx.bboxes[i] = p.boundingBox()
	}
	return idx
}

// Subset は指定範囲と bbox が重なるポリゴンだけを含む新しい Index を返す。
// 全国規模の Index (数十万ポリゴン) を対象メッシュ周辺に絞り込んでから Intersects を
// 繰り返し呼ぶことで、全ポリゴンの bbox 走査をエッジ数×3 回ではなく 1 回に抑えられる。
func (idx *Index) Subset(minLon, minLat, maxLon, maxLat float64) *Index {
	var polys []Polygon
	var bboxes []bbox
	for i, b := range idx.bboxes {
		if maxLon < b.minLon || minLon > b.maxLon || maxLat < b.minLat || minLat > b.maxLat {
			continue
		}
		polys = append(polys, idx.polys[i])
		bboxes = append(bboxes, b)
	}
	return &Index{polys: polys, bboxes: bboxes}
}

// Intersects は線分 (道路グラフのエッジ) がいずれかのポリゴンと交差するか近似判定する。
// 両端点と中点をサンプルする。2 次メッシュ内の短い辺が前提の近似であり、
// 両端点が外でもポリゴンの角をかすめて通過する辺は見逃し得る (ADR-0003 に明記)。
func (idx *Index) Intersects(lat1, lon1, lat2, lon2 float64) bool {
	minLon, maxLon := math.Min(lon1, lon2), math.Max(lon1, lon2)
	minLat, maxLat := math.Min(lat1, lat2), math.Max(lat1, lat2)
	midLat, midLon := (lat1+lat2)/2, (lon1+lon2)/2

	for i, p := range idx.polys {
		b := idx.bboxes[i]
		if maxLon < b.minLon || minLon > b.maxLon || maxLat < b.minLat || minLat > b.maxLat {
			continue
		}
		if p.Contains(lat1, lon1) || p.Contains(lat2, lon2) || p.Contains(midLat, midLon) {
			return true
		}
	}
	return false
}
