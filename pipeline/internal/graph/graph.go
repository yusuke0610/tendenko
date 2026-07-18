// Package graph は OSM の way から歩行者用道路グラフを構築する。
// エッジは無向で 1 本ずつ収載し、端末側ローダーが逆向きを展開する (ADR-0003)。
package graph

import (
	"github.com/yusuke0610/tendenko/pipeline/internal/geo"
	"github.com/yusuke0610/tendenko/pipeline/internal/osmxml"
)

// エッジ属性フラグ。端末側の動的コスト関数が参照する (FR-12)。
const (
	FlagSteps      uint32 = 1 << 0 // 階段
	FlagPrivate    uint32 = 1 << 1 // access=private/no
	FlagBridge     uint32 = 1 << 2 // 橋
	FlagInundation uint32 = 1 << 3 // 津波浸水想定区域内 (TODO: A40 取り込み後に付与)
)

// Edge は way の隣接ノード間セグメント。Grade は書き出し時に標高から計算する。
type Edge struct {
	From, To   int64
	LengthM    float64
	BearingDeg float64
	Flags      uint32
}

// walkableHighways は避難歩行に使える highway 値。
// motorway/trunk (自動車専用) は除外する。
var walkableHighways = map[string]bool{
	"footway": true, "path": true, "steps": true, "pedestrian": true,
	"living_street": true, "residential": true, "unclassified": true,
	"service": true, "track": true, "cycleway": true,
	"tertiary": true, "tertiary_link": true,
	"secondary": true, "secondary_link": true,
	"primary": true, "primary_link": true,
	"road": true,
}

// Walkable は way を道路グラフに含めるか判定する。
func Walkable(tags map[string]string) bool {
	return walkableHighways[tags["highway"]]
}

// Build は kept way からエッジ列と使用ノード集合を作る。
// 座標が不明なノード (抽出境界の外) を含むセグメントは捨てる。
func Build(nodes map[int64]osmxml.Node, ways []osmxml.Way) (map[int64]osmxml.Node, []Edge) {
	used := make(map[int64]osmxml.Node)
	var edges []Edge
	for _, w := range ways {
		flags := wayFlags(w.Tags)
		for i := 0; i+1 < len(w.NodeIDs); i++ {
			a, okA := nodes[w.NodeIDs[i]]
			b, okB := nodes[w.NodeIDs[i+1]]
			if !okA || !okB {
				continue
			}
			used[a.ID] = a
			used[b.ID] = b
			edges = append(edges, Edge{
				From:       a.ID,
				To:         b.ID,
				LengthM:    geo.DistanceM(a.Lat, a.Lon, b.Lat, b.Lon),
				BearingDeg: geo.BearingDeg(a.Lat, a.Lon, b.Lat, b.Lon),
				Flags:      flags,
			})
		}
	}
	return used, edges
}

func wayFlags(tags map[string]string) uint32 {
	var f uint32
	if tags["highway"] == "steps" {
		f |= FlagSteps
	}
	if a := tags["access"]; a == "private" || a == "no" {
		f |= FlagPrivate
	}
	if tags["bridge"] != "" && tags["bridge"] != "no" {
		f |= FlagBridge
	}
	return f
}
