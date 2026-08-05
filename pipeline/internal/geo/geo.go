// Package geo は距離・方位の計算を提供する。
package geo

import "math"

const earthRadiusM = 6371000.0

// DistanceM は 2 点間の大円距離 (メートル、haversine)。
func DistanceM(lat1, lon1, lat2, lon2 float64) float64 {
	φ1, φ2 := lat1*math.Pi/180, lat2*math.Pi/180
	dφ := (lat2 - lat1) * math.Pi / 180
	dλ := (lon2 - lon1) * math.Pi / 180
	a := math.Sin(dφ/2)*math.Sin(dφ/2) + math.Cos(φ1)*math.Cos(φ2)*math.Sin(dλ/2)*math.Sin(dλ/2)
	// a は理論上 0…1 だが、対蹠点に近いと丸め誤差で 1 をわずかに超え、math.Sqrt(1-a) が NaN になる。
	// 端末側の GeoPoint.distanceM と同じ式を保つため、クランプもこちらに揃える
	a = math.Min(math.Max(a, 0), 1)
	return earthRadiusM * 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

// BearingDeg は点 1 から点 2 への初期方位角 (0-360°、北 = 0)。
func BearingDeg(lat1, lon1, lat2, lon2 float64) float64 {
	φ1, φ2 := lat1*math.Pi/180, lat2*math.Pi/180
	dλ := (lon2 - lon1) * math.Pi / 180
	y := math.Sin(dλ) * math.Cos(φ2)
	x := math.Cos(φ1)*math.Sin(φ2) - math.Sin(φ1)*math.Cos(φ2)*math.Cos(dλ)
	deg := math.Atan2(y, x) * 180 / math.Pi
	return math.Mod(deg+360, 360)
}
