package dem

import (
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseTile(t *testing.T) {
	// "e" はデータなし (NaN)
	tl := parseTile([]byte("1.5,2.5,e\r\n-3.25"))
	if tl.vals[0] != 1.5 || tl.vals[1] != 2.5 {
		t.Errorf("row 0 = %v, %v", tl.vals[0], tl.vals[1])
	}
	if !math.IsNaN(tl.vals[2]) {
		t.Errorf("'e' should be NaN, got %v", tl.vals[2])
	}
	if tl.vals[tileSize] != -3.25 {
		t.Errorf("row 1 col 0 = %v, want -3.25", tl.vals[tileSize])
	}
	if !math.IsNaN(tl.vals[tileSize+1]) {
		t.Error("未指定のピクセルは NaN のはず")
	}
}

// uniformTile は全ピクセルが同じ値のタイル CSV を作る。
func uniformTile(v string) string {
	row := strings.Repeat(v+",", tileSize-1) + v
	rows := make([]string, tileSize)
	for i := range rows {
		rows[i] = row
	}
	return strings.Join(rows, "\n")
}

func TestElevationFetchAndCache(t *testing.T) {
	requests := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		_, _ = w.Write([]byte(uniformTile("123.4")))
	}))
	defer srv.Close()

	cacheDir := t.TempDir()
	c := NewClient(cacheDir)
	c.BaseURL = srv.URL

	elev, ok, err := c.Elevation(39.2758, 141.8850) // 釜石
	if err != nil || !ok || elev != 123.4 {
		t.Fatalf("elev = %v ok=%v err=%v, want 123.4", elev, ok, err)
	}
	if requests != 1 {
		t.Errorf("requests = %d, want 1", requests)
	}

	// 同じタイル内の別地点はメモリキャッシュで解決 (リクエスト増えない)
	if _, _, err := c.Elevation(39.2760, 141.8851); err != nil {
		t.Fatal(err)
	}
	if requests != 1 {
		t.Errorf("requests after memory-cache hit = %d, want 1", requests)
	}

	// 新しいクライアントはディスクキャッシュで解決 (サーバー停止後でも動く)
	srv.Close()
	c2 := NewClient(cacheDir)
	c2.BaseURL = srv.URL
	elev, ok, err = c2.Elevation(39.2758, 141.8850)
	if err != nil || !ok || elev != 123.4 {
		t.Errorf("disk-cached elev = %v ok=%v err=%v, want 123.4", elev, ok, err)
	}
}

func TestElevationMissingTile(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer srv.Close()

	c := NewClient(t.TempDir())
	c.BaseURL = srv.URL
	_, ok, err := c.Elevation(39.30, 142.5) // 海上 → 404
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Error("404 タイルは ok=false のはず")
	}
}
