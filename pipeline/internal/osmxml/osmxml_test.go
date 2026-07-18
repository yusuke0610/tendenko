package osmxml

import (
	"strings"
	"testing"
)

const sample = `<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6">
  <node id="1" lat="39.25" lon="141.90"/>
  <node id="2" lat="39.26" lon="141.91"/>
  <node id="3" lat="39.27" lon="141.92"/>
  <way id="10">
    <nd ref="1"/><nd ref="2"/>
    <tag k="highway" v="residential"/>
    <tag k="name" v="テスト通り"/>
  </way>
  <way id="11">
    <nd ref="2"/><nd ref="3"/>
    <tag k="building" v="yes"/>
  </way>
  <relation id="20">
    <member type="way" ref="10" role="outer"/>
  </relation>
</osm>`

func TestParse(t *testing.T) {
	nodes, ways, err := Parse(strings.NewReader(sample), func(tags map[string]string) bool {
		return tags["highway"] != ""
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(nodes) != 3 {
		t.Errorf("nodes = %d, want 3", len(nodes))
	}
	if n := nodes[2]; n.Lat != 39.26 || n.Lon != 141.91 {
		t.Errorf("node 2 = (%v, %v), want (39.26, 141.91)", n.Lat, n.Lon)
	}
	// building way は keepWay=false で捨てられる
	if len(ways) != 1 {
		t.Fatalf("ways = %d, want 1", len(ways))
	}
	w := ways[0]
	if w.ID != 10 {
		t.Errorf("way id = %d, want 10", w.ID)
	}
	if len(w.NodeIDs) != 2 || w.NodeIDs[0] != 1 || w.NodeIDs[1] != 2 {
		t.Errorf("way nodes = %v, want [1 2]", w.NodeIDs)
	}
	if w.Tags["name"] != "テスト通り" {
		t.Errorf("way name = %q", w.Tags["name"])
	}
}

func TestParseBrokenXML(t *testing.T) {
	if _, _, err := Parse(strings.NewReader("<osm><node id="), nil); err == nil {
		t.Error("broken XML should return error")
	}
}
