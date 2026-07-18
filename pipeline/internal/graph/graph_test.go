package graph

import (
	"testing"

	"github.com/yusuke0610/tendenko/pipeline/internal/osmxml"
)

func TestWalkable(t *testing.T) {
	cases := []struct {
		tags map[string]string
		want bool
	}{
		{map[string]string{"highway": "residential"}, true},
		{map[string]string{"highway": "steps"}, true},
		{map[string]string{"highway": "motorway"}, false},
		{map[string]string{"highway": "trunk"}, false},
		{map[string]string{"building": "yes"}, false},
		{map[string]string{}, false},
	}
	for _, c := range cases {
		if got := Walkable(c.tags); got != c.want {
			t.Errorf("Walkable(%v) = %v, want %v", c.tags, got, c.want)
		}
	}
}

func TestBuild(t *testing.T) {
	nodes := map[int64]osmxml.Node{
		1: {ID: 1, Lat: 39.25, Lon: 141.90},
		2: {ID: 2, Lat: 39.26, Lon: 141.90},
		3: {ID: 3, Lat: 39.27, Lon: 141.90},
	}
	ways := []osmxml.Way{
		// ノード 99 は座標不明 (抽出境界の外) → 1-99, 99-3 のセグメントは捨てられる
		{ID: 10, NodeIDs: []int64{1, 2, 99, 3}, Tags: map[string]string{"highway": "steps", "bridge": "yes"}},
	}
	used, edges := Build(nodes, ways)
	if len(edges) != 1 {
		t.Fatalf("edges = %d, want 1", len(edges))
	}
	e := edges[0]
	if e.From != 1 || e.To != 2 {
		t.Errorf("edge = %d→%d, want 1→2", e.From, e.To)
	}
	if e.Flags&FlagSteps == 0 || e.Flags&FlagBridge == 0 {
		t.Errorf("flags = %b, want steps|bridge", e.Flags)
	}
	if e.LengthM < 1000 || e.LengthM > 1300 {
		t.Errorf("length = %.0fm, want ≈1112m (緯度 0.01°)", e.LengthM)
	}
	if len(used) != 2 {
		t.Errorf("used nodes = %d, want 2", len(used))
	}
}
