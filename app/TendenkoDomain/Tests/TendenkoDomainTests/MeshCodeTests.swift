import Testing

@testable import TendenkoDomain

// pipeline/internal/mesh (Go) と同一アルゴリズムであることを既知コードで検証する。
// 緯度経度↔2 次メッシュ変換は JIS X 0410 の固定式 (ADR-0003 / ADR-0004)。
@Suite("MeshCode — 2 次メッシュ計算 (JIS X 0410)")
struct MeshCodeTests {
    @Test("釜石中心部の緯度経度が 584177 になる (Go SecondaryCode と一致)")
    func kamaishiFromCoordinate() {
        #expect(MeshCode(latitude: 39.29, longitude: 141.94).code == "584177")
    }

    @Test("東京都心の緯度経度が 533946 になる")
    func tokyoFromCoordinate() {
        // ADR-0003 で最大パッケージとして登場する東京都心メッシュ
        #expect(MeshCode(latitude: 35.70, longitude: 139.80).code == "533946")
    }

    @Test("6 桁でないコードは不正")
    func invalidCodeRejected() {
        #expect(MeshCode("58417") == nil)
        #expect(MeshCode("5841777") == nil)
        #expect(MeshCode("abcdef") == nil)
        #expect(MeshCode("584188") == nil) // q/v は 0-7
    }

    @Test("正しい 6 桁コードは受理される")
    func validCodeAccepted() {
        #expect(MeshCode("584177")?.code == "584177")
    }

    @Test("bbox は南西端を含み北東端の一歩手前まで (584177)")
    func bboxOfKamaishi() {
        let bbox = MeshCode("584177")!.bbox
        #expect(abs(bbox.minLat - 39.25) < 1e-9)
        #expect(abs(bbox.minLon - 141.875) < 1e-9)
        #expect(abs(bbox.maxLat - (39.25 + 1.0 / 12)) < 1e-9)
        #expect(abs(bbox.maxLon - 142.0) < 1e-9)
    }

    @Test("bbox の中心から逆算すると同じメッシュコードに戻る (往復整合)")
    func roundTripThroughBBoxCenter() {
        for code in ["584177", "533946", "503324", "362257"] {
            let bbox = MeshCode(code)!.bbox
            let mid = MeshCode(latitude: (bbox.minLat + bbox.maxLat) / 2,
                               longitude: (bbox.minLon + bbox.maxLon) / 2)
            #expect(mid.code == code)
        }
    }

    @Test("3×3 近傍はちょうど 9 メッシュで自分自身を含む")
    func neighborhood3x3() {
        let center = MeshCode("584177")!
        let hood = center.neighborhood(ring: 1)
        #expect(hood.count == 9)
        #expect(hood.contains(center))
    }

    @Test("近傍の各メッシュは中心の隣接式と一致する (Go fromIndices と同じ)")
    func neighborhoodMatchesAdjacency() {
        // 584177: latIdx=58*8+7=471, lonIdx=41*8+7=335
        let hood = Set(MeshCode("584177")!.neighborhood(ring: 1).map(\.code))
        // 東西/南北に 1 ずつずらした既知の隣接コード
        #expect(hood.contains("584176")) // 西 (v: 7→6)
        #expect(hood.contains("584167")) // 南 (q: 7→6)
        #expect(hood.contains("584166")) // 南西
        #expect(hood.contains("594107")) // 北 (q 桁上がり: latIdx 472 → p=59,q=0)
        #expect(hood.contains("584270")) // 東 (v 桁上がり: lonIdx 336 → u=42,v=0)
    }

    @Test("ring=0 は自分自身だけ")
    func neighborhoodRingZero() {
        let center = MeshCode("584177")!
        #expect(center.neighborhood(ring: 0) == [center])
    }
}
