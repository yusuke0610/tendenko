package mesh

import (
	"math"
	"testing"
)

func TestParseSecondaryKamaishi(t *testing.T) {
	// 釜石市中心部 (39.2758N, 141.8850E) を含むメッシュ
	bbox, err := ParseSecondary("584177")
	if err != nil {
		t.Fatal(err)
	}
	almost := func(got, want float64) bool { return math.Abs(got-want) < 1e-9 }
	if !almost(bbox.MinLat, 39.25) || !almost(bbox.MinLon, 141.875) {
		t.Errorf("min = (%v, %v), want (39.25, 141.875)", bbox.MinLat, bbox.MinLon)
	}
	if !almost(bbox.MaxLat, 39.25+1.0/12) || !almost(bbox.MaxLon, 142.0) {
		t.Errorf("max = (%v, %v), want (%v, 142.0)", bbox.MaxLat, bbox.MaxLon, 39.25+1.0/12)
	}
}

func TestParseSecondaryHyphenated(t *testing.T) {
	a, _ := ParseSecondary("584177")
	b, err := ParseSecondary("5841-77")
	if err != nil || a != b {
		t.Errorf("hyphenated form should parse identically: %v vs %v (err=%v)", a, b, err)
	}
}

func TestParseSecondaryInvalid(t *testing.T) {
	for _, c := range []string{"", "5841", "58417", "5841789", "584179", "abcdef"} {
		if _, err := ParseSecondary(c); err == nil {
			t.Errorf("ParseSecondary(%q) should fail", c)
		}
	}
}

func TestSecondaryCodeRoundTrip(t *testing.T) {
	// 釜石市中心部が 584177 に入ること
	if got := SecondaryCode(39.2758, 141.8850); got != "584177" {
		t.Errorf("SecondaryCode(釜石) = %s, want 584177", got)
	}
	// メッシュ内の任意点が同じコードに戻ること
	bbox, _ := ParseSecondary("584177")
	midLat := (bbox.MinLat + bbox.MaxLat) / 2
	midLon := (bbox.MinLon + bbox.MaxLon) / 2
	if got := SecondaryCode(midLat, midLon); got != "584177" {
		t.Errorf("SecondaryCode(mid) = %s, want 584177", got)
	}
}
