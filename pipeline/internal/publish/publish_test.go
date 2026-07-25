package publish

import "testing"

func TestObjectKey(t *testing.T) {
	cases := map[string]string{
		"manifest.json":        "manifest.json",
		"region-584177.sqlite": "packages/region-584177.sqlite",
		"tiles-584177.mbtiles": "packages/tiles-584177.mbtiles",
	}
	for in, want := range cases {
		if got := ObjectKey(in); got != want {
			t.Errorf("ObjectKey(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestUploadable(t *testing.T) {
	yes := []string{"manifest.json", "region-584177.sqlite", "tiles-584177.mbtiles"}
	no := []string{"extracts.json", "parent-5841.osm.pbf", "mesh-584177.osm", "region-584177.sqlite.tmp", ".DS_Store"}
	for _, n := range yes {
		if !Uploadable(n) {
			t.Errorf("Uploadable(%q) = false, want true", n)
		}
	}
	for _, n := range no {
		if Uploadable(n) {
			t.Errorf("Uploadable(%q) = true, want false", n)
		}
	}
}

func TestParseGSURL(t *testing.T) {
	cases := []struct {
		in             string
		bucket, prefix string
		wantErr        bool
	}{
		{"gs://tendenko-packages", "tendenko-packages", "", false},
		{"gs://tendenko-packages/", "tendenko-packages", "", false},
		{"gs://tendenko-packages/v1", "tendenko-packages", "v1", false},
		{"gs://tendenko-packages/v1/", "tendenko-packages", "v1", false},
		{"gs://tendenko-packages/a/b", "tendenko-packages", "a/b", false},
		{"tendenko-packages", "", "", true},   // gs:// なし
		{"gs://", "", "", true},               // バケット名なし
		{"https://example.com", "", "", true}, // スキーム違い
	}
	for _, c := range cases {
		bucket, prefix, err := ParseGSURL(c.in)
		if c.wantErr {
			if err == nil {
				t.Errorf("ParseGSURL(%q) expected error, got nil", c.in)
			}
			continue
		}
		if err != nil {
			t.Errorf("ParseGSURL(%q) unexpected error: %v", c.in, err)
			continue
		}
		if bucket != c.bucket || prefix != c.prefix {
			t.Errorf("ParseGSURL(%q) = (%q, %q), want (%q, %q)", c.in, bucket, prefix, c.bucket, c.prefix)
		}
	}
}

func TestKeyWithPrefix(t *testing.T) {
	if got := keyWithPrefix("", "manifest.json"); got != "manifest.json" {
		t.Errorf("keyWithPrefix empty = %q", got)
	}
	if got := keyWithPrefix("v1", "region-584177.sqlite"); got != "v1/packages/region-584177.sqlite" {
		t.Errorf("keyWithPrefix v1 = %q", got)
	}
}
