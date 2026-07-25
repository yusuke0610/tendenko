/// 緯度経度の点。地図描画・最近傍探索など座標を扱う純粋ロジックで使う。
public struct GeoPoint: Hashable, Sendable {
    public let lat: Double
    public let lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// 指定緊急避難場所 (災害種別: 津波)。region.sqlite の shelters テーブルに対応 (ADR-0003)。
/// 値型なのでドメインに置き、経路探索の goal 選定に使う。読み込みは Storage 層 (ShelterLoader)。
public struct Shelter: Hashable, Sendable {
    public let name: String
    public let point: GeoPoint
    /// 標高 (m)。DEM なしは nil
    public let elevM: Double?

    public init(name: String, point: GeoPoint, elevM: Double?) {
        self.name = name
        self.point = point
        self.elevM = elevM
    }
}
