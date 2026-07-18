// Package dem は地理院標高タイル (DEM10B, テキスト形式) から標高を引く。
// https://maps.gsi.go.jp/development/ichiran.html#dem
// タイルはディスクにキャッシュし、再実行時はネットワークに出ない。
package dem

import (
	"fmt"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	zoom     = 14 // DEM10B の最大ズーム
	tileSize = 256
	baseURL  = "https://cyberjapandata.gsi.go.jp/xyz/dem/%d/%d/%d.txt"
)

// Client は標高タイルの取得とルックアップを行う。
type Client struct {
	CacheDir string
	HTTP     *http.Client

	tiles map[[2]int]*tile // key: {x, y}
}

// tile は 256x256 の標高値。NaN は水面・データなし。
type tile struct {
	vals [tileSize * tileSize]float64
}

func NewClient(cacheDir string) *Client {
	return &Client{
		CacheDir: cacheDir,
		HTTP:     &http.Client{Timeout: 30 * time.Second},
		tiles:    map[[2]int]*tile{},
	}
}

// Elevation は経緯度の標高 (m) を返す。データなし (海など) は ok=false。
func (c *Client) Elevation(lat, lon float64) (elev float64, ok bool, err error) {
	n := math.Exp2(zoom)
	xf := (lon + 180) / 360 * n
	yf := (1 - math.Log(math.Tan(lat*math.Pi/180)+1/math.Cos(lat*math.Pi/180))/math.Pi) / 2 * n
	tx, ty := int(xf), int(yf)
	px := int((xf - float64(tx)) * tileSize)
	py := int((yf - float64(ty)) * tileSize)

	t, err := c.tile(tx, ty)
	if err != nil {
		return 0, false, err
	}
	if t == nil {
		return 0, false, nil // タイル自体が存在しない (海域)
	}
	v := t.vals[py*tileSize+px]
	if math.IsNaN(v) {
		return 0, false, nil
	}
	return v, true, nil
}

func (c *Client) tile(x, y int) (*tile, error) {
	key := [2]int{x, y}
	if t, hit := c.tiles[key]; hit {
		return t, nil
	}
	raw, err := c.fetch(x, y)
	if err != nil {
		return nil, err
	}
	var t *tile
	if raw != nil {
		t = parseTile(raw)
	}
	c.tiles[key] = t
	return t, nil
}

// fetch はキャッシュ→ネットワークの順でタイルを取得する。404 (海域) は nil を返し、
// キャッシュには空ファイルとして記録する。
func (c *Client) fetch(x, y int) ([]byte, error) {
	path := filepath.Join(c.CacheDir, fmt.Sprintf("%d-%d-%d.txt", zoom, x, y))
	if b, err := os.ReadFile(path); err == nil {
		if len(b) == 0 {
			return nil, nil
		}
		return b, nil
	}
	url := fmt.Sprintf(baseURL, zoom, x, y)
	resp, err := c.HTTP.Get(url)
	if err != nil {
		return nil, fmt.Errorf("dem: %s: %w", url, err)
	}
	defer resp.Body.Close()
	var body []byte
	switch resp.StatusCode {
	case http.StatusOK:
		body = make([]byte, 0, 256*1024)
		buf := make([]byte, 32*1024)
		for {
			n, err := resp.Body.Read(buf)
			body = append(body, buf[:n]...)
			if err != nil {
				break
			}
		}
	case http.StatusNotFound:
		body = nil
	default:
		return nil, fmt.Errorf("dem: %s: HTTP %d", url, resp.StatusCode)
	}
	if err := os.MkdirAll(c.CacheDir, 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		return nil, err
	}
	return body, nil
}

func parseTile(raw []byte) *tile {
	t := &tile{}
	for i := range t.vals {
		t.vals[i] = math.NaN()
	}
	for row, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if row >= tileSize {
			break
		}
		for col, s := range strings.Split(strings.TrimRight(line, "\r"), ",") {
			if col >= tileSize {
				break
			}
			if v, err := strconv.ParseFloat(s, 64); err == nil {
				t.vals[row*tileSize+col] = v
			} // "e" (データなし) は NaN のまま
		}
	}
	return t
}
