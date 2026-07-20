package inundation

import (
	"os"
	"path/filepath"
	"testing"
)

// square は (0,0)-(10,10) (lon,lat) の正方形。
var square = Polygon{Rings: [][][2]float64{
	{{0, 0}, {10, 0}, {10, 10}, {0, 10}, {0, 0}},
}}

func TestPolygonContains(t *testing.T) {
	cases := []struct {
		name     string
		lat, lon float64
		want     bool
	}{
		{"内部", 5, 5, true},
		{"外部", 15, 15, false},
		{"外部 (片軸のみ範囲内)", 5, 15, false},
	}
	for _, c := range cases {
		if got := square.Contains(c.lat, c.lon); got != c.want {
			t.Errorf("%s: Contains(%v,%v) = %v, want %v", c.name, c.lat, c.lon, got, c.want)
		}
	}
}

func TestPolygonWithHole(t *testing.T) {
	// 外周 (0,0)-(10,10)、穴 (4,4)-(6,6)
	p := Polygon{Rings: [][][2]float64{
		{{0, 0}, {10, 0}, {10, 10}, {0, 10}, {0, 0}},
		{{4, 4}, {6, 4}, {6, 6}, {4, 6}, {4, 4}},
	}}
	if !p.Contains(2, 2) {
		t.Error("穴の外の内部点は Contains=true のはず")
	}
	if p.Contains(5, 5) {
		t.Error("穴の中の点は Contains=false のはず")
	}
}

func TestIndexIntersects(t *testing.T) {
	idx := NewIndex([]Polygon{square})

	cases := []struct {
		name                   string
		lat1, lon1, lat2, lon2 float64
		want                   bool
	}{
		{"両端点が内部", 3, 3, 7, 7, true},
		{"片端点が内部", 5, 5, 20, 20, true},
		{"中点のみ内部 (両端は外)", -5, 5, 15, 5, true},
		{"完全に無関係", 100, 100, 200, 200, false},
		{"bbox 前置フィルタで早期棄却される距離", -100, -100, -90, -90, false},
	}
	for _, c := range cases {
		if got := idx.Intersects(c.lat1, c.lon1, c.lat2, c.lon2); got != c.want {
			t.Errorf("%s: Intersects = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestIndexSubset(t *testing.T) {
	far := Polygon{Rings: [][][2]float64{{{100, 100}, {110, 100}, {110, 110}, {100, 110}, {100, 100}}}}
	idx := NewIndex([]Polygon{square, far})

	sub := idx.Subset(-1, -1, 11, 11) // square を含み far を含まない範囲
	if len(sub.polys) != 1 {
		t.Fatalf("Subset polys = %d, want 1", len(sub.polys))
	}
	if !sub.Intersects(5, 5, 5, 5) {
		t.Error("Subset 後も square との交差判定は成立するはず")
	}
	if sub.Intersects(105, 105, 105, 105) {
		t.Error("Subset で除外したはずの far と交差判定されてしまっている")
	}
}

func TestLoad(t *testing.T) {
	geojson := `{
		"type": "FeatureCollection",
		"features": [
			{"type": "Feature", "properties": {}, "geometry":
				{"type": "Polygon", "coordinates": [[[0,0],[10,0],[10,10],[0,10],[0,0]]]}},
			{"type": "Feature", "properties": {}, "geometry":
				{"type": "MultiPolygon", "coordinates": [
					[[[20,20],[30,20],[30,30],[20,30],[20,20]]],
					[[[40,40],[50,40],[50,50],[40,50],[40,40]]]
				]}},
			{"type": "Feature", "properties": {}, "geometry":
				{"type": "Point", "coordinates": [0, 0]}}
		]
	}`
	path := filepath.Join(t.TempDir(), "test.geojson")
	if err := os.WriteFile(path, []byte(geojson), 0o644); err != nil {
		t.Fatal(err)
	}

	polys, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	// Polygon 1 件 + MultiPolygon の 2 件 = 3 件。Point は無視される。
	if len(polys) != 3 {
		t.Fatalf("polys = %d, want 3", len(polys))
	}
	if !polys[0].Contains(5, 5) {
		t.Error("最初のポリゴンが正しく読めていない")
	}
	if !polys[2].Contains(45, 45) {
		t.Error("MultiPolygon の 2 件目が正しく読めていない")
	}
}
