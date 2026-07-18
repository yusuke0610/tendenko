package geo

import (
	"math"
	"testing"
)

func TestDistanceM(t *testing.T) {
	// 緯度 1 分 ≈ 1852m (39°N 付近でも緯度方向は一定)
	d := DistanceM(39.0, 141.9, 39.0+1.0/60, 141.9)
	if math.Abs(d-1852) > 10 {
		t.Errorf("1 分の緯度差 = %.1fm, want ≈1852m", d)
	}
	if DistanceM(39.25, 141.875, 39.25, 141.875) != 0 {
		t.Error("同一点の距離は 0")
	}
}

func TestBearingDeg(t *testing.T) {
	cases := []struct {
		name                   string
		lat1, lon1, lat2, lon2 float64
		want, tol              float64
	}{
		{"真北", 39.0, 141.9, 39.1, 141.9, 0, 0.01},
		{"真東", 39.0, 141.9, 39.0, 142.0, 90, 0.5},
		{"真南", 39.1, 141.9, 39.0, 141.9, 180, 0.01},
		{"真西", 39.0, 142.0, 39.0, 141.9, 270, 0.5},
	}
	for _, c := range cases {
		got := BearingDeg(c.lat1, c.lon1, c.lat2, c.lon2)
		diff := math.Abs(got - c.want)
		if diff > 180 {
			diff = 360 - diff
		}
		if diff > c.tol {
			t.Errorf("%s: bearing = %.2f°, want %.2f°", c.name, got, c.want)
		}
	}
}
