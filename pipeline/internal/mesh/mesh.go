// Package mesh は JIS X 0410 地域メッシュの計算を提供する。
// 地域パッケージの分割単位は 2 次メッシュ (ADR-0003)。
package mesh

import (
	"fmt"
	"regexp"
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
	var p, u, q, v int
	fmt.Sscanf(m[1], "%2d%2d", &p, &u)
	fmt.Sscanf(m[2], "%d", &q)
	fmt.Sscanf(m[3], "%d", &v)
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
