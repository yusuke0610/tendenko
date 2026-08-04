import Foundation

/// 緯度経度の点。地図描画・最近傍探索など座標を扱う純粋ロジックで使う。
public struct GeoPoint: Hashable, Sendable {
    public let lat: Double
    public let lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

extension GeoPoint {
    /// 地球半径 (m)。pipeline の `geo` パッケージと同じ値を使う。
    /// パイプラインが `edges.length_m` に焼き込んだ距離と端末側の実測距離が食い違わないようにする。
    static let earthRadiusM = 6_371_000.0

    /// 2 点間の大円距離 (m、haversine)。pipeline の `geo.DistanceM` と同じ式。
    public func distanceM(to other: GeoPoint) -> Double {
        let phi1 = lat * .pi / 180
        let phi2 = other.lat * .pi / 180
        let dPhi = (other.lat - lat) * .pi / 180
        let dLambda = (other.lon - lon) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return Self.earthRadiusM * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
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
