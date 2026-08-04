import Testing

@testable import TendenkoDomain

/// 緯度 0.001 度 ≒ 111m。テストはこの刻みで経路を組み立てる。
private let latStep = 0.001
private func p(_ latOffset: Double, _ lonOffset: Double = 0) -> GeoPoint {
    GeoPoint(lat: 39.0 + latOffset, lon: 141.9 + lonOffset)
}

private func step(_ point: GeoPoint, _ maneuver: Maneuver = .turn(.right)) -> GuidanceStep {
    GuidanceStep(nodeID: 0, point: point, maneuver: maneuver,
                 distanceFromPreviousM: 0, text: "テスト")
}

/// 北へ 111m 刻みで 5 点の直線経路。
private let straightLine = (0..<5).map { p(Double($0) * latStep) }

@Suite("GeoPoint の距離 (pipeline の geo.DistanceM と同じ式)")
struct GeoPointDistanceTests {
    @Test("緯度 1 分は約 1852m")
    func oneArcMinute() {
        let d = p(0).distanceM(to: p(1.0 / 60))
        #expect(abs(d - 1852) < 10)
    }

    @Test("同一点の距離は 0")
    func samePoint() {
        #expect(p(0).distanceM(to: p(0)) == 0)
    }

    @Test("距離は対称")
    func symmetric() {
        let a = p(0), b = p(0.01, 0.02)
        #expect(abs(a.distanceM(to: b) - b.distanceM(to: a)) < 0.001)
    }
}

@Suite("RouteGeometry — 点から経路までの距離")
struct PolylineDistanceTests {
    @Test("経路上の点までの距離は 0")
    func onTheLine() {
        let d = RouteGeometry.distanceToPolylineM(p(latStep), polyline: straightLine)
        #expect(d < 1)
    }

    @Test("線分の途中に落ちる垂線の距離を返す")
    func perpendicular() {
        // 2 点の中間から東へずれた点。経度 0.001 度 ≒ 86m (39°N)
        let off = GeoPoint(lat: 39.0 + latStep / 2, lon: 141.9 + 0.001)
        let d = RouteGeometry.distanceToPolylineM(off, polyline: straightLine)
        #expect(abs(d - 86) < 5)
    }

    @Test("経路の端より外側は端点までの距離になる")
    func beyondEndpoint() {
        let before = p(-latStep) // 始点より 111m 手前
        let d = RouteGeometry.distanceToPolylineM(before, polyline: straightLine)
        #expect(abs(d - 111) < 5)
    }

    @Test("1 点だけの経路はその点までの距離")
    func singlePoint() {
        let d = RouteGeometry.distanceToPolylineM(p(latStep), polyline: [p(0)])
        #expect(abs(d - 111) < 5)
    }

    @Test("空の経路は無限遠 (逸脱判定では常に逸脱になる)")
    func emptyPolyline() {
        #expect(RouteGeometry.distanceToPolylineM(p(0), polyline: []).isInfinite)
    }
}

@Suite("RouteTracker — 現在地への追従 (FR-14 逸脱検知 / FR-16 到達検知)")
struct RouteTrackerTests {
    private let steps = [step(p(0), .start(bearingDeg: 0)),
                         step(p(2 * latStep)),
                         step(p(4 * latStep), .arrive(shelterName: "高台"))]

    // MARK: - 逸脱検知 (FR-14)

    @Test("経路上にいれば逸脱していない")
    func onRoute() {
        let state = RouteTracker.track(location: p(latStep), steps: steps, polyline: straightLine)
        #expect(!state.isOffRoute)
        #expect(state.offRouteDistanceM < 1)
    }

    @Test("許容幅を超えて離れたら逸脱")
    func offRoute() {
        // 東へ 0.002 度 ≒ 173m。既定の許容 40m を超える
        let away = GeoPoint(lat: 39.0 + latStep, lon: 141.9 + 0.002)
        let state = RouteTracker.track(location: away, steps: steps, polyline: straightLine)
        #expect(state.isOffRoute)
        #expect(state.offRouteDistanceM > 150)
    }

    @Test("GPS 誤差程度のずれでは逸脱としない")
    func toleratesGPSNoise() {
        // 東へ 0.0002 度 ≒ 17m。既定の許容 40m 以内
        let jitter = GeoPoint(lat: 39.0 + latStep, lon: 141.9 + 0.0002)
        #expect(!RouteTracker.track(location: jitter, steps: steps, polyline: straightLine).isOffRoute)
    }

    @Test("許容幅は調整できる")
    func toleranceIsConfigurable() {
        var style = TrackingStyle()
        style.offRouteToleranceM = 200
        let away = GeoPoint(lat: 39.0 + latStep, lon: 141.9 + 0.002) // 約 173m
        #expect(!RouteTracker.track(location: away, steps: steps, polyline: straightLine,
                                    style: style).isOffRoute)
    }

    // MARK: - 到達検知 (FR-16)

    @Test("最後の案内地点に十分近づいたら到達")
    func arrives() {
        let state = RouteTracker.track(location: p(4 * latStep), steps: steps,
                                       polyline: straightLine)
        #expect(state.hasArrived)
    }

    @Test("目的地から離れていれば未到達")
    func notArrivedYet() {
        let state = RouteTracker.track(location: p(latStep), steps: steps, polyline: straightLine)
        #expect(!state.hasArrived)
    }

    @Test("案内が空なら到達判定はしない")
    func noStepsNoArrival() {
        let state = RouteTracker.track(location: p(0), steps: [], polyline: straightLine)
        #expect(!state.hasArrived)
        #expect(state.stepIndex == 0)
        #expect(state.distanceToNextStepM == nil)
    }

    // MARK: - 案内の進行

    @Test("出発地点にいるとき、次に案内すべきは 2 番目の指示")
    func startAdvancesPastFirstStep() {
        // 出発の指示は現在地そのものなので通過済みとして扱う
        let state = RouteTracker.track(location: p(0), steps: steps, polyline: straightLine)
        #expect(state.stepIndex == 1)
    }

    @Test("案内地点を通過するとインデックスが進む")
    func advancesOnReachingStep() {
        let state = RouteTracker.track(location: p(2 * latStep), steps: steps,
                                       polyline: straightLine)
        #expect(state.stepIndex == 2)
    }

    @Test("次の案内地点までの残距離を返す")
    func reportsDistanceToNextStep() {
        let state = RouteTracker.track(location: p(latStep), steps: steps, polyline: straightLine)
        #expect(state.stepIndex == 1)
        // 現在地 (111m 地点) から 2 番目の指示 (222m 地点) まで約 111m
        #expect(abs((state.distanceToNextStepM ?? 0) - 111) < 5)
    }

    @Test("すべて通過したら次は無く、残距離も無い")
    func allStepsPassed() {
        let state = RouteTracker.track(location: p(4 * latStep), steps: steps,
                                       polyline: straightLine)
        #expect(state.stepIndex == steps.count)
        #expect(state.distanceToNextStepM == nil)
    }

    @Test("進行は後戻りしない")
    func neverGoesBackwards() {
        // 2 番目の指示を通過済みの状態で、出発地点に戻っても巻き戻らない。
        // 測位のふらつきで案内が前の指示に戻ると、同じ指示を何度も読み上げてしまう
        let state = RouteTracker.track(location: p(0), steps: steps, polyline: straightLine,
                                       fromStepIndex: 2)
        #expect(state.stepIndex == 2)
    }

    @Test("範囲外の fromStepIndex を渡しても壊れない")
    func clampsOutOfRangeIndex() {
        let over = RouteTracker.track(location: p(0), steps: steps, polyline: straightLine,
                                      fromStepIndex: 99)
        #expect(over.stepIndex == steps.count)

        let under = RouteTracker.track(location: p(0), steps: steps, polyline: straightLine,
                                       fromStepIndex: -5)
        #expect(under.stepIndex == 1)
    }
}
