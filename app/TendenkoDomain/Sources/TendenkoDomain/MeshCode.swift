/// JIS X 0410 の 2 次メッシュ (約 10km 四方)。地域パッケージの分割単位 (ADR-0003)。
///
/// 緯度経度↔メッシュコードの変換式は pipeline/internal/mesh (Go) と同一。
/// 純粋な値型なのでドメイン層に置き、シミュレータ不要で TDD する (ADR-0004)。
public struct MeshCode: Hashable, Sendable, CustomStringConvertible {
    /// 6 桁の 2 次メッシュコード (例: "584177")。
    public let code: String

    public var description: String { code }

    /// 6 桁・各桁が数字・q/v が 0-7 のときだけ受理する。
    public init?(_ code: String) {
        guard let parts = Self.parts(of: code) else { return nil }
        // 正規化 (ゼロ埋めの揺れを吸収) して保持する。
        self.code = Self.format(parts)
    }

    /// 緯度経度が属する 2 次メッシュを計算する (Go mesh.SecondaryCode と同式)。
    /// 日本国内 (北緯・東経 100° 台) を前提とする。
    public init(latitude: Double, longitude: Double) {
        let p = Int(latitude * 1.5)
        let u = Int(longitude) - 100
        let q = Int((latitude * 1.5 - Double(p)) * 8)
        let v = Int((longitude - Double(Int(longitude))) * 8)
        self.code = Self.format((p: p, u: u, q: q, v: v))
    }

    /// このメッシュが覆う緯度経度の矩形範囲 (南西端を含み、北東端は隣メッシュの南西端)。
    public var bbox: MeshBBox {
        let (p, u, q, v) = Self.parts(of: code)! // init で検証済み
        let minLat = Double(p) * 2 / 3 + Double(q) * 1 / 12
        let minLon = 100 + Double(u) + Double(v) * 1 / 8
        return MeshBBox(minLat: minLat, minLon: minLon,
                        maxLat: minLat + 1.0 / 12, maxLon: minLon + 1.0 / 8)
    }

    /// 自分を中心に ring リング分の近傍メッシュを返す (ring=1 で 3×3 = 9 個)。
    /// ローリングキャッシュの desired set に使う (ADR-0004)。
    /// メッシュコードの連番 (latIdx = p*8+q, lonIdx = u*8+v) 上で格子的に隣接を取る。
    public func neighborhood(ring: Int = 1) -> [MeshCode] {
        let (p, u, q, v) = Self.parts(of: code)!
        let latIdx = p * 8 + q
        let lonIdx = u * 8 + v
        var out: [MeshCode] = []
        out.reserveCapacity((2 * ring + 1) * (2 * ring + 1))
        for dy in -ring...ring {
            for dx in -ring...ring {
                out.append(Self.fromIndices(latIdx: latIdx + dy, lonIdx: lonIdx + dx))
            }
        }
        return out
    }

    // MARK: - コード ↔ 内部表現

    private static func parts(of code: String) -> (p: Int, u: Int, q: Int, v: Int)? {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return nil }
        let d = Array(code)
        guard let p = Int(String(d[0...1])), let u = Int(String(d[2...3])),
              let q = Int(String(d[4])), let v = Int(String(d[5])),
              q <= 7, v <= 7
        else { return nil }
        return (p, u, q, v)
    }

    private static func format(_ parts: (p: Int, u: Int, q: Int, v: Int)) -> String {
        // Foundation 非依存を保つため手動でゼロ埋めする (ドメイン層は依存ゼロ)。
        pad2(parts.p) + pad2(parts.u) + String(parts.q) + String(parts.v)
    }

    private static func pad2(_ n: Int) -> String {
        n < 10 ? "0" + String(n) : String(n)
    }

    private static func fromIndices(latIdx: Int, lonIdx: Int) -> MeshCode {
        let code = format((p: latIdx / 8, u: lonIdx / 8, q: latIdx % 8, v: lonIdx % 8))
        return MeshCode(code)! // 連番からの生成は常に妥当
    }
}

/// メッシュが覆う経緯度の矩形範囲。
public struct MeshBBox: Hashable, Sendable {
    public let minLat: Double
    public let minLon: Double
    public let maxLat: Double
    public let maxLon: Double

    public init(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        self.minLat = minLat
        self.minLon = minLon
        self.maxLat = maxLat
        self.maxLon = maxLon
    }

    /// 中心座標 (地図の初期表示に使う)。
    public var center: (lat: Double, lon: Double) {
        ((minLat + maxLat) / 2, (minLon + maxLon) / 2)
    }
}
