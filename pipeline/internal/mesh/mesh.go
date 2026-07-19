// Package mesh は JIS X 0410 地域メッシュの計算を提供する。
// 地域パッケージの分割単位は 2 次メッシュ (ADR-0003)。
package mesh

import (
	"fmt"
	"regexp"
	"strconv"
)

// BBox は経緯度の矩形範囲。
type BBox struct {
	MinLat, MinLon, MaxLat, MaxLon float64
}

var code2Pattern = regexp.MustCompile(`^(\d{4})-?(\d)(\d)$`)

// ParseSecondary は 2 次メッシュコード (例: "584177" または "5841-77") を範囲に変換する。
func ParseSecondary(code string) (BBox, error) {
	m := code2Pattern.FindStringSubmatch(code)
	if m == nil {
		return BBox{}, fmt.Errorf("mesh: invalid secondary mesh code %q", code)
	}
	p, u, q, v := meshParts(m)
	if q > 7 || v > 7 {
		return BBox{}, fmt.Errorf("mesh: invalid secondary mesh code %q (q/v must be 0-7)", code)
	}
	minLat := float64(p)*2/3 + float64(q)*1/12
	minLon := 100 + float64(u) + float64(v)*1/8
	return BBox{
		MinLat: minLat,
		MinLon: minLon,
		MaxLat: minLat + 1.0/12,
		MaxLon: minLon + 1.0/8,
	}, nil
}

// SecondaryCode は経緯度が属する 2 次メッシュコードを返す。
func SecondaryCode(lat, lon float64) string {
	p := int(lat * 1.5)
	u := int(lon) - 100
	q := int((lat*1.5 - float64(p)) * 8)
	v := int((lon - float64(int(lon))) * 8)
	return fmt.Sprintf("%02d%02d%d%d", p, u, q, v)
}

// ParsePrimary は 1 次メッシュコード (例: "5841") を範囲に変換する。
func ParsePrimary(code string) (BBox, error) {
	if len(code) != 4 {
		return BBox{}, fmt.Errorf("mesh: invalid primary mesh code %q", code)
	}
	p, err1 := strconv.Atoi(code[:2])
	u, err2 := strconv.Atoi(code[2:])
	if err1 != nil || err2 != nil {
		return BBox{}, fmt.Errorf("mesh: invalid primary mesh code %q", code)
	}
	minLat := float64(p) * 2 / 3
	minLon := 100 + float64(u)
	return BBox{MinLat: minLat, MinLon: minLon, MaxLat: minLat + 2.0/3, MaxLon: minLon + 1}, nil
}

// indices は 2 次メッシュコードを南北・東西の連番に変換する (隣接計算用)。
func indices(code string) (latIdx, lonIdx int, err error) {
	m := code2Pattern.FindStringSubmatch(code)
	if m == nil {
		return 0, 0, fmt.Errorf("mesh: invalid secondary mesh code %q", code)
	}
	p, u, q, v := meshParts(m)
	return p*8 + q, u*8 + v, nil
}

// meshParts は正規表現でマッチ済みの部分文字列を数値に変換する (数字のみと検証済み)。
func meshParts(m []string) (p, u, q, v int) {
	p, _ = strconv.Atoi(m[1][:2])
	u, _ = strconv.Atoi(m[1][2:])
	q, _ = strconv.Atoi(m[2])
	v, _ = strconv.Atoi(m[3])
	return
}

func fromIndices(latIdx, lonIdx int) string {
	return fmt.Sprintf("%02d%02d%d%d", latIdx/8, lonIdx/8, latIdx%8, lonIdx%8)
}

// Expand は与えたメッシュ集合に隣接 ring リング分のメッシュを加えて返す。
// ring=1 で約 10km のバッファに相当する (ADR-0003 の沿岸バッファ)。
func Expand(codes map[string]bool, ring int) (map[string]bool, error) {
	out := make(map[string]bool, len(codes)*2)
	for code := range codes {
		latIdx, lonIdx, err := indices(code)
		if err != nil {
			return nil, err
		}
		for dy := -ring; dy <= ring; dy++ {
			for dx := -ring; dx <= ring; dx++ {
				out[fromIndices(latIdx+dy, lonIdx+dx)] = true
			}
		}
	}
	return out, nil
}
