package shelterdata

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/yusuke0610/tendenko/pipeline/internal/mesh"
)

const sample = `{
	"type": "FeatureCollection",
	"features": [
		{"type": "Feature", "properties": {"name": "釜石中学校", "tsunami": true},
			"geometry": {"type": "Point", "coordinates": [141.885, 39.2758]}},
		{"type": "Feature", "properties": {"name": "洪水のみの避難所", "tsunami": false},
			"geometry": {"type": "Point", "coordinates": [141.0, 39.0]}},
		{"type": "Feature", "properties": {"name": "遠方の津波避難場所", "tsunami": true},
			"geometry": {"type": "Point", "coordinates": [130.0, 30.0]}}
	]
}`

func TestLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "shelters.geojson")
	if err := os.WriteFile(path, []byte(sample), 0o644); err != nil {
		t.Fatal(err)
	}
	shelters, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	// tsunami=false の 1 件は除外される
	if len(shelters) != 2 {
		t.Fatalf("shelters = %d, want 2", len(shelters))
	}
	if shelters[0].Name != "釜石中学校" || shelters[0].Lat != 39.2758 || shelters[0].Lon != 141.885 {
		t.Errorf("shelters[0] = %+v", shelters[0])
	}
}

func TestInBBox(t *testing.T) {
	shelters := []Shelter{
		{Name: "圏内", Lat: 39.26, Lon: 141.90},
		{Name: "圏外", Lat: 10.0, Lon: 100.0},
	}
	bbox, _ := mesh.ParseSecondary("584177")
	got := InBBox(shelters, bbox)
	if len(got) != 1 || got[0].Name != "圏内" {
		t.Errorf("InBBox = %+v, want [圏内]", got)
	}
}
