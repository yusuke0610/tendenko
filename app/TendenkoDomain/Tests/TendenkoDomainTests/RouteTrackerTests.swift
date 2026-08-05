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

/// 九十九折り。北へ 444m 登り、東へ 26m ずれて折り返し、444m 南下する。
/// 折り返した先の区間は往路から 26m しか離れていないので、GPS 誤差で往路より近くなりうる。
/// 道なり距離では 0m / 444m / 470m / 914m と大きく離れている
private let hairpin = [p(0), p(4 * latStep),
                       GeoPoint(lat: 39.0 + 4 * latStep, lon: 141.9 + 0.0003),
                       GeoPoint(lat: 39.0, lon: 141.9 + 0.0003)]

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

    @Test("対蹠点でも NaN にならない")
    func nearAntipodal() {
        // haversine の中間値が丸め誤差で 1 を超える組み合わせ。クランプが無いと
        // (1 - a) の平方根が NaN になり、逸脱判定・到達判定が両方とも偽になる
        let d = GeoPoint(lat: 0.0074, lon: 141.9).distanceM(to: GeoPoint(lat: -0.0074, lon: -38.1))
        #expect(!d.isNaN)
        #expect(abs(d - .pi * 6_371_000) < 1)
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

@Suite("RouteGeometry — 経路上への射影")
struct RouteProjectionTests {
    /// 往路 (北上) の 111m 地点から東へ 17m ずれた測位。折り返した先の復路までは 8.6m しかない
    private let noisyOnOutbound = GeoPoint(lat: 39.0 + latStep, lon: 141.9 + 0.0002)

    @Test("各頂点の道なり距離を返す")
    func cumulativeDistances() {
        let cumulative = RouteGeometry.cumulativeDistancesM(hairpin)
        #expect(cumulative.count == hairpin.count)
        #expect(cumulative[0] == 0)
        #expect(abs(cumulative[1] - 444) < 5)
        #expect(abs(cumulative[2] - 470) < 5)
        #expect(abs(cumulative[3] - 914) < 10)
    }

    @Test("空の経路は射影できない")
    func emptyPolylineHasNoProjection() {
        #expect(RouteGeometry.project(p(0), onto: []) == nil)
    }

    @Test("九十九折りでは経路全体の最近傍が折り返した先の区間になる")
    func globalNearestJumpsAtHairpin() {
        // 窓を設けない射影は復路 (26m 東の並走区間) を選ぶ。これが進行に化けると
        // 折り返しの案内をまとめて飛ばすので、RouteTracker は窓付きで射影する
        let projection = RouteGeometry.project(noisyOnOutbound, onto: hairpin)
        #expect(projection != nil)
        #expect((projection?.progressM ?? 0) > 700)
    }

    @Test("探索範囲を渡すと範囲外の区間は候補にならない")
    func searchRangeExcludesFarSegments() {
        let projection = RouteGeometry.project(noisyOnOutbound, onto: hairpin,
                                               searchRangeM: 111...261)
        #expect(abs((projection?.progressM ?? 0) - 111) < 20)
        #expect(abs((projection?.distanceM ?? 0) - 17) < 5)
    }

    @Test("探索範囲に掛かる区間が無ければ射影できない")
    func searchRangeWithoutCandidate() {
        #expect(RouteGeometry.project(p(0), onto: hairpin, searchRangeM: 2000...3000) == nil)
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

    // MARK: - 進行の探索範囲 (九十九折り・並走路)

    private let hairpinSteps = [step(hairpin[0], .start(bearingDeg: 0)),
                                step(hairpin[1], .turn(.sharpRight)),
                                step(hairpin[2], .turn(.sharpRight)),
                                step(hairpin[3], .arrive(shelterName: "高台"))]

    @Test("九十九折りで折り返した先が近くても、進行は飛ばない")
    func doesNotJumpAcrossHairpin() {
        // 往路 111m 地点で東へ 17m の測位誤差。復路 (26m 東) までは 8.6m しかないので、
        // 経路全体の最近傍を進行に使うと 800m 先まで飛び、折り返しの案内 2 つを捨ててしまう
        let noisy = GeoPoint(lat: 39.0 + latStep, lon: 141.9 + 0.0002)
        let state = RouteTracker.track(location: noisy, steps: hairpinSteps, polyline: hairpin,
                                       fromStepIndex: 1, fromProgressM: 111)
        #expect(state.stepIndex == 1)
        #expect(abs(state.progressM - 111) < 20)
        #expect(!state.isOffRoute) // 経路からは 8.6m しか離れていないので逸脱ではない
    }

    @Test("窓の外まで進んでいても、経路上にいれば進行は追いつく")
    func recoversFromLargeJump() {
        // 測位が途切れて終点 (444m) まで進んだ状態。窓 (既定 150m) の中には許容幅以内の
        // 区間が無いので経路全体の最近傍に戻す。ここで戻さないと案内が窓の縁で止まる
        let state = RouteTracker.track(location: p(4 * latStep), steps: steps,
                                       polyline: straightLine, fromStepIndex: 1,
                                       fromProgressM: 0)
        #expect(state.stepIndex == steps.count)
        #expect(abs(state.progressM - 444) < 5)
    }

    @Test("進行は次の更新に渡せる道なり距離として返る")
    func reportsProgress() {
        let state = RouteTracker.track(location: p(latStep), steps: steps, polyline: straightLine)
        #expect(abs(state.progressM - 111) < 5)
    }

    @Test("窓を広げると九十九折りをまたいだ最近傍を拾う (窓が効いていることの裏取り)")
    func windowIsConfigurable() {
        var style = TrackingStyle()
        style.progressWindowM = 1000
        let noisy = GeoPoint(lat: 39.0 + latStep, lon: 141.9 + 0.0002)
        let state = RouteTracker.track(location: noisy, steps: hairpinSteps, polyline: hairpin,
                                       fromStepIndex: 1, fromProgressM: 111, style: style)
        #expect(state.progressM > 700)
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
