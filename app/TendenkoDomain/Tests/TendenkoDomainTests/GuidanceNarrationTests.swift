import Testing

@testable import TendenkoDomain

private func point(_ lat: Double = 39.0, _ lon: Double = 141.9) -> GeoPoint {
    GeoPoint(lat: lat, lon: lon)
}

/// 案内 1 件。文言は `GuidanceScript` が作るので、ここでは識別できる文字列を置く。
private func step(_ text: String, _ maneuver: Maneuver = .turn(.right),
                  fromPreviousM: Double = 100) -> GuidanceStep {
    GuidanceStep(nodeID: 0, point: point(), maneuver: maneuver,
                 distanceFromPreviousM: fromPreviousM, text: text)
}

/// 出発 → 右折 → 到達の 3 件。区間長は既定で短く (都市部相当)、進捗案内は出ない
private let shortLegs = [
    step("出発", .start(bearingDeg: 0), fromPreviousM: 0),
    step("右折", .turn(.right), fromPreviousM: 120),
    step("到達", .arrive(shelterName: "鵜住居小学校"), fromPreviousM: 150),
]

/// 右折までが 3,000m ある山道相当。ADR-0007 の「無案内区間」の再現
private let longLegs = [
    step("出発", .start(bearingDeg: 0), fromPreviousM: 0),
    step("右折", .turn(.right), fromPreviousM: 3000),
    step("到達", .arrive(shelterName: "東前樋が沢"), fromPreviousM: 200),
]

private func tracking(stepIndex: Int, offRoute: Bool = false, arrived: Bool = false,
                      toNextM: Double? = nil) -> TrackingState {
    TrackingState(stepIndex: stepIndex,
                  offRouteDistanceM: offRoute ? 100 : 5,
                  isOffRoute: offRoute,
                  hasArrived: arrived,
                  distanceToNextStepM: toNextM,
                  progressM: 0)
}

@Suite("GuidanceNarration — 案内の開始")
struct NarrationOpeningTests {

    @Test("開始時は概要・歩き出す方向・次の指示を読む")
    func opening() {
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 1), steps: shortLegs,
                                       summary: "概要", previous: .initial, now: 0)
        #expect(n.texts == ["概要", "出発", "右折"])
        #expect(!n.needsReroute)
        #expect(n.state.announcedStepIndex == 1)
    }

    @Test("概要が無くても歩き出す方向は読む")
    func openingWithoutSummary() {
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 1), steps: shortLegs,
                                       summary: nil, previous: .initial, now: 0)
        #expect(n.texts == ["出発", "右折"])
    }

    @Test("進行が動かなければ読み直さない")
    func doesNotRepeat() {
        let first = GuidanceNarration.next(tracking: tracking(stepIndex: 1), steps: shortLegs,
                                           summary: "概要", previous: .initial, now: 0)
        let second = GuidanceNarration.next(tracking: tracking(stepIndex: 1), steps: shortLegs,
                                            summary: "概要", previous: first.state, now: 1)
        #expect(second.texts.isEmpty)
    }

    @Test("案内が無ければ何も読まない")
    func emptySteps() {
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 0), steps: [],
                                       summary: "概要", previous: .initial, now: 0)
        #expect(n.texts.isEmpty)
        #expect(!n.needsReroute)
    }
}

@Suite("GuidanceNarration — 指示の進行")
struct NarrationAdvanceTests {

    @Test("指示が進んだら次の指示を読む")
    func advances() {
        let opened = GuidanceNarration.next(tracking: tracking(stepIndex: 1), steps: shortLegs,
                                            summary: nil, previous: .initial, now: 0)
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 2), steps: shortLegs,
                                       summary: nil, previous: opened.state, now: 10)
        #expect(n.texts == ["到達"])
        #expect(n.state.announcedStepIndex == 2)
    }

    @Test("最後まで通過し終えたら黙る (到達検知は別)")
    func pastLastStep() {
        let opened = GuidanceNarration.next(tracking: tracking(stepIndex: 1), steps: shortLegs,
                                            summary: nil, previous: .initial, now: 0)
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: shortLegs.count),
                                       steps: shortLegs, summary: nil,
                                       previous: opened.state, now: 10)
        #expect(n.texts.isEmpty)
        #expect(n.state.announcedStepIndex == shortLegs.count)
    }
}

@Suite("GuidanceNarration — 進捗案内 (ADR-0007 の無案内区間)")
struct NarrationProgressTests {

    /// 開始済み・区間の残りが `remainingM` の状態
    private func afterOpening(_ legs: [GuidanceStep]) -> NarrationState {
        GuidanceNarration.next(tracking: tracking(stepIndex: 1, toNextM: 3000), steps: legs,
                               summary: nil, previous: .initial, now: 0).state
    }

    @Test("長い区間では残距離のしきい値で進捗を読む")
    func announcesProgressOnLongLeg() {
        let state = afterOpening(longLegs)
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 1, toNextM: 950),
                                       steps: longLegs, summary: nil, previous: state, now: 60)
        // 同じ指示を残距離で読み直す (GuidanceScript の文言をそのまま使う)
        #expect(n.texts == ["950メートル先、右に曲がります"])
        #expect(n.state.announcedCueM == 1000)
    }

    @Test("同じしきい値は 2 度読まない")
    func announcesEachThresholdOnce() {
        let state = afterOpening(longLegs)
        let first = GuidanceNarration.next(tracking: tracking(stepIndex: 1, toNextM: 950),
                                           steps: longLegs, summary: nil, previous: state, now: 60)
        let second = GuidanceNarration.next(tracking: tracking(stepIndex: 1, toNextM: 900),
                                            steps: longLegs, summary: nil,
                                            previous: first.state, now: 90)
        #expect(second.texts.isEmpty)
    }

    @Test("次のしきい値まで進んだら再び読む")
    func announcesNextThreshold() {
        let state = afterOpening(longLegs)
        let first = GuidanceNarration.next(tracking: tracking(stepIndex: 1, toNextM: 950),
                                           steps: longLegs, summary: nil, previous: state, now: 60)
        let second = GuidanceNarration.next(tracking: tracking(stepIndex: 1, toNextM: 480),
                                            steps: longLegs, summary: nil,
                                            previous: first.state, now: 400)
        #expect(second.texts == ["500メートル先、右に曲がります"])
        #expect(second.state.announcedCueM == 500)
    }

    @Test("大きく進んだらしきい値を飛ばして最も近いものを読む")
    func skipsMissedThresholds() {
        let state = afterOpening(longLegs)
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 1, toNextM: 150),
                                       steps: longLegs, summary: nil, previous: state, now: 600)
        #expect(n.state.announcedCueM == 200)
        #expect(n.texts == ["150メートル先、右に曲がります"])
    }

    @Test("短い区間 (都市部) では進捗を読まない")
    func silentOnShortLeg() {
        let state = GuidanceNarration.next(tracking: tracking(stepIndex: 1, toNextM: 120),
                                           steps: shortLegs, summary: nil,
                                           previous: .initial, now: 0).state
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 1, toNextM: 60),
                                       steps: shortLegs, summary: nil, previous: state, now: 30)
        #expect(n.texts.isEmpty)
    }

    @Test("指示が進んだら進捗のしきい値は初期化される")
    func resetsCueOnAdvance() {
        let state = afterOpening(longLegs)
        let cued = GuidanceNarration.next(tracking: tracking(stepIndex: 1, toNextM: 150),
                                          steps: longLegs, summary: nil, previous: state, now: 600)
        #expect(cued.state.announcedCueM == 200)
        let advanced = GuidanceNarration.next(tracking: tracking(stepIndex: 2, toNextM: 190),
                                              steps: longLegs, summary: nil,
                                              previous: cued.state, now: 700)
        #expect(advanced.texts == ["到達"])
        #expect(advanced.state.announcedCueM == nil)
    }
}

@Suite("GuidanceNarration — 逸脱とリルート (FR-14)")
struct NarrationOffRouteTests {

    private var opened: NarrationState {
        GuidanceNarration.next(tracking: tracking(stepIndex: 1), steps: shortLegs,
                               summary: nil, previous: .initial, now: 0).state
    }

    @Test("逸脱の立ち上がりで通知しリルートを要求する")
    func risingEdge() {
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 1, offRoute: true),
                                       steps: shortLegs, summary: nil, previous: opened, now: 5)
        #expect(n.needsReroute)
        #expect(n.texts == ["経路を外れました。新しい経路を案内します"])
        #expect(n.state.lastRerouteAt == 5)
    }

    @Test("逸脱が続く間は通知を繰り返さない")
    func doesNotRepeatNotice() {
        let first = GuidanceNarration.next(tracking: tracking(stepIndex: 1, offRoute: true),
                                           steps: shortLegs, summary: nil, previous: opened, now: 5)
        let second = GuidanceNarration.next(tracking: tracking(stepIndex: 1, offRoute: true),
                                            steps: shortLegs, summary: nil,
                                            previous: first.state, now: 7)
        #expect(second.texts.isEmpty)
        #expect(!second.needsReroute)
    }

    @Test("逸脱が続いたら間隔を空けてリルートを再試行する")
    func retriesAfterInterval() {
        let first = GuidanceNarration.next(tracking: tracking(stepIndex: 1, offRoute: true),
                                           steps: shortLegs, summary: nil, previous: opened, now: 5)
        let retry = GuidanceNarration.next(tracking: tracking(stepIndex: 1, offRoute: true),
                                           steps: shortLegs, summary: nil,
                                           previous: first.state, now: 15)
        #expect(retry.needsReroute)
        // 再試行は黙って行う。外れている間ずっと喋り続けない
        #expect(retry.texts.isEmpty)
    }

    @Test("案内の開始と同時に逸脱していてもリルートしない")
    func doesNotRerouteAtOpening() {
        // 経路はこの現在地から引かれたばかり。ここでリルートすると同じ経路を引き直し続ける
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 1, offRoute: true),
                                       steps: shortLegs, summary: nil, previous: .initial, now: 0)
        #expect(!n.needsReroute)
        #expect(n.texts == ["出発", "右折"])
        #expect(n.state.wasOffRoute)
    }

    @Test("逸脱中は進行も進捗も読まない")
    func silentWhileOffRoute() {
        let first = GuidanceNarration.next(tracking: tracking(stepIndex: 1, offRoute: true),
                                           steps: longLegs, summary: nil, previous: opened, now: 5)
        let second = GuidanceNarration.next(tracking: tracking(stepIndex: 2, offRoute: true,
                                                               toNextM: 150),
                                            steps: longLegs, summary: nil,
                                            previous: first.state, now: 7)
        #expect(second.texts.isEmpty)
    }

    @Test("経路に戻れば逸脱状態は解除される")
    func recovers() {
        let off = GuidanceNarration.next(tracking: tracking(stepIndex: 1, offRoute: true),
                                         steps: shortLegs, summary: nil, previous: opened, now: 5)
        let back = GuidanceNarration.next(tracking: tracking(stepIndex: 1), steps: shortLegs,
                                          summary: nil, previous: off.state, now: 8)
        #expect(!back.state.wasOffRoute)
        #expect(!back.needsReroute)
    }
}

@Suite("GuidanceNarration — 到達 (FR-16)")
struct NarrationArrivalTests {

    private var opened: NarrationState {
        GuidanceNarration.next(tracking: tracking(stepIndex: 1), steps: shortLegs,
                               summary: nil, previous: .initial, now: 0).state
    }

    @Test("到達したらその場に留まり解除を待つよう案内する")
    func announcesArrival() {
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 2, arrived: true),
                                       steps: shortLegs, summary: nil, previous: opened, now: 100)
        #expect(n.texts == ["鵜住居小学校に到着しました。その場に留まり、警報が解除されるまで待ってください"])
        #expect(n.state.hasAnnouncedArrival)
    }

    @Test("到達は 1 度しか読まない")
    func announcesOnce() {
        let first = GuidanceNarration.next(tracking: tracking(stepIndex: 2, arrived: true),
                                           steps: shortLegs, summary: nil, previous: opened, now: 100)
        let second = GuidanceNarration.next(tracking: tracking(stepIndex: 2, arrived: true),
                                            steps: shortLegs, summary: nil,
                                            previous: first.state, now: 101)
        #expect(second.texts.isEmpty)
    }

    @Test("到達後は逸脱してもリルートしない")
    func noRerouteAfterArrival() {
        let arrived = GuidanceNarration.next(tracking: tracking(stepIndex: 2, arrived: true),
                                             steps: shortLegs, summary: nil,
                                             previous: opened, now: 100)
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 2, offRoute: true,
                                                          arrived: true),
                                       steps: shortLegs, summary: nil,
                                       previous: arrived.state, now: 120)
        #expect(!n.needsReroute)
        #expect(n.texts.isEmpty)
    }

    @Test("避難場所名が引けなければ「避難場所」で縮退する")
    func fallsBackToGenericName() {
        let legs = [step("出発", .start(bearingDeg: 0), fromPreviousM: 0),
                    step("到達", .arrive(shelterName: nil), fromPreviousM: 150)]
        let opened = GuidanceNarration.next(tracking: tracking(stepIndex: 1), steps: legs,
                                            summary: nil, previous: .initial, now: 0)
        let n = GuidanceNarration.next(tracking: tracking(stepIndex: 1, arrived: true),
                                       steps: legs, summary: nil, previous: opened.state, now: 50)
        #expect(n.texts.first?.hasPrefix("避難場所に到着しました") == true)
    }
}
