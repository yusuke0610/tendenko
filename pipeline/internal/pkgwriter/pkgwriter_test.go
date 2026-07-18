package pkgwriter

import (
	"database/sql"
	"math"
	"path/filepath"
	"testing"
)

func TestWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "region-584177.sqlite")
	nodes := []NodeRow{
		{ID: 1, Lat: 39.25, Lon: 141.90, ElevM: 12.5},
		{ID: 2, Lat: 39.26, Lon: 141.91, ElevM: math.NaN()}, // 標高なし → NULL
	}
	edges := []EdgeRow{
		{From: 1, To: 2, LengthM: 1500, Grade: 0.02, BearingDeg: 45, Flags: 5},
	}
	if err := Write(path, "584177", "test-source", nodes, edges); err != nil {
		t.Fatal(err)
	}

	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	var n int
	if err := db.QueryRow("SELECT COUNT(*) FROM nodes").Scan(&n); err != nil || n != 2 {
		t.Errorf("nodes = %d (err=%v), want 2", n, err)
	}
	if err := db.QueryRow("SELECT COUNT(*) FROM nodes WHERE elev_m IS NULL").Scan(&n); err != nil || n != 1 {
		t.Errorf("NULL elev nodes = %d (err=%v), want 1", n, err)
	}

	var length float64
	var flags int
	if err := db.QueryRow("SELECT length_m, flags FROM edges WHERE from_id = 1").Scan(&length, &flags); err != nil {
		t.Fatal(err)
	}
	if length != 1500 || flags != 5 {
		t.Errorf("edge = (%v, %v), want (1500, 5)", length, flags)
	}

	var meshVal string
	if err := db.QueryRow("SELECT value FROM meta WHERE key = 'mesh'").Scan(&meshVal); err != nil || meshVal != "584177" {
		t.Errorf("meta mesh = %q (err=%v), want 584177", meshVal, err)
	}

	// エッジ探索用のインデックスが両方向に存在すること
	for _, idx := range []string{"idx_edges_from", "idx_edges_to"} {
		var cnt int
		if err := db.QueryRow("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?", idx).Scan(&cnt); err != nil || cnt != 1 {
			t.Errorf("index %s missing (err=%v)", idx, err)
		}
	}
}

func TestWriteRefusesExistingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "region.sqlite")
	if err := Write(path, "584177", "s", nil, nil); err != nil {
		t.Fatal(err)
	}
	if err := Write(path, "584177", "s", nil, nil); err == nil {
		t.Error("second Write to same path should fail (schema already exists)")
	}
}
