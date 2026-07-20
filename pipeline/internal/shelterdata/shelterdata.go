// Package shelterdata は指定緊急避難場所 (災害種別: 津波、FR-04/FR-11 の目的地) を読み込む。
//
// 入力は正規化された GeoJSON (Point の FeatureCollection、properties.tsunami == true
// のもののみ採用) を受け付ける。国土地理院・各自治体の実データはこの形式に変換してから
// 渡す。実データの取得元・変換手順は ADR-0003 に追記する (URL は要確認のため未着手)。
package shelterdata

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/yusuke0610/tendenko/pipeline/internal/mesh"
)

type Shelter struct {
	Name     string
	Lat, Lon float64
}

// Load は GeoJSON FeatureCollection から津波避難場所 (properties.tsunami == true) を読み込む。
func Load(path string) ([]Shelter, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("shelterdata: %w", err)
	}
	var fc struct {
		Features []struct {
			Geometry struct {
				Type        string    `json:"type"`
				Coordinates []float64 `json:"coordinates"` // [lon, lat]
			} `json:"geometry"`
			Properties struct {
				Name    string `json:"name"`
				Tsunami bool   `json:"tsunami"`
			} `json:"properties"`
		} `json:"features"`
	}
	if err := json.Unmarshal(data, &fc); err != nil {
		return nil, fmt.Errorf("shelterdata: %s: %w", path, err)
	}

	var shelters []Shelter
	for i, f := range fc.Features {
		if f.Geometry.Type != "Point" {
			continue
		}
		if !f.Properties.Tsunami {
			continue
		}
		if len(f.Geometry.Coordinates) != 2 {
			return nil, fmt.Errorf("shelterdata: feature %d: coordinates は [lon, lat] の 2 要素が必要", i)
		}
		shelters = append(shelters, Shelter{
			Name: f.Properties.Name,
			Lon:  f.Geometry.Coordinates[0],
			Lat:  f.Geometry.Coordinates[1],
		})
	}
	return shelters, nil
}

// InBBox はメッシュ範囲内の避難場所だけを返す (パッケージにメッシュ外のデータを含めないため)。
func InBBox(shelters []Shelter, bbox mesh.BBox) []Shelter {
	var out []Shelter
	for _, s := range shelters {
		if s.Lat >= bbox.MinLat && s.Lat <= bbox.MaxLat && s.Lon >= bbox.MinLon && s.Lon <= bbox.MaxLon {
			out = append(out, s)
		}
	}
	return out
}
