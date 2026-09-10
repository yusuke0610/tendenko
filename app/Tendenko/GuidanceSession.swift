import Foundation
import Observation
import TendenkoDomain

/// 案内フェーズの状態を持ち、現在地の更新を追従と発話に繋ぐ (FR-13/FR-14/FR-16、ADR-0008)。
///
/// 判断はすべてドメイン層の純粋関数が行う。ここがやるのは
/// 「前回の進行を覚えて `RouteTracker` に渡す」「`GuidanceNarration` が返した文を読み上げる」
/// 「リルートが要ると言われたことを呼び出し側に伝える」の 3 つだけで、分岐を持たない。
@MainActor
@Observable
final class GuidanceSession {
    /// 案内フェーズにいるか。連続測位の生存区間と一致する (ADR-0008)
    private(set) var isActive = false
    /// 目的地に到達したか (FR-16)。到達したら追従を止めてよい
    private(set) var hasArrived = false
    /// 追従中の経路。リルートで差し替わる
    private(set) var polyline: [GeoPoint] = []

    private var steps: [GuidanceStep] = []
    private var summary: String?
    private var narration = NarrationState.initial
    /// 前回の追従結果。`RouteTracker` は進行を後戻りさせないためにこれを必要とする
    private var stepIndex = 0
    private var progressM = 0.0

    /// 発話は UI 層の責務 (ADR-0007)。`RegionCacheCoordinator` が `CLLocationManager` を
    /// 自前で持つのと同じ流儀で、ここで組み立てる
    private let announcer = SpeechAnnouncer()

    /// 経路が確定したので案内を開始する (リルート後の再開も同じ入口)。
    ///
    /// **経路が変わっていなければ読み上げの進行を引き継ぐ。** リルートが結果的に同じ経路を
    /// 返すことはあり (現在地がグラフから離れている等)、そのたびに概要から読み直すと
    /// 同じ案内を繰り返し聞かせることになる。
    func begin(polyline: [GeoPoint], steps: [GuidanceStep], summary: String?, at location: GeoPoint) {
        // 到達済みなら案内し直さない (FR-16)。着いた後も測位は続くので、ここを開けておくと
        // 避難場所を始点にした新しい経路で案内が再開してしまう。地域が変われば `reset()` で戻す
        guard !hasArrived else { return }
        if polyline != self.polyline {
            narration = .initial
            stepIndex = 0
            progressM = 0
        }
        self.polyline = polyline
        self.steps = steps
        self.summary = summary
        isActive = true
        // 開始と同時に読み上げる。FR-11 の「起動の瞬間に音声が流れている」はここで満たす。
        // 戻り値のリルート要求は無視する — 開始直後にリルートを掛けると、たった今この現在地から
        // 引いたばかりの経路を引き直すことになる (`GuidanceNarration` も開始時は要求しない)
        _ = update(location: location)
    }

    /// 現在地が届いたときの追従。リルートが必要なら true を返す (実行は呼び出し側)。
    @discardableResult
    func update(location: GeoPoint, now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard isActive, !steps.isEmpty else { return false }

        let tracking = RouteTracker.track(location: location, steps: steps, polyline: polyline,
                                          fromStepIndex: stepIndex, fromProgressM: progressM)
        stepIndex = tracking.stepIndex
        progressM = tracking.progressM

        let narrated = GuidanceNarration.next(tracking: tracking, steps: steps, summary: summary,
                                              previous: narration, now: now)
        narration = narrated.state
        if !narrated.texts.isEmpty {
            announcer.announce(narrated.texts)
        }
        if tracking.hasArrived {
            hasArrived = true
        }
        return narrated.needsReroute
    }

    /// 案内フェーズを抜ける。
    ///
    /// **読み上げ中の発話は打ち切らない。** 抜ける理由は到達 (FR-16) かフォアグラウンド離脱で、
    /// 前者では到達案内を、後者では画面ロック後も続く案内を途中で切ることになる。
    /// ADR-0007 のとおり `.playback` は画面ロック中も鳴る構成であり、そこで黙らせる理由がない。
    /// 復帰時は `begin` からやり直す (`polyline` が同じなら進行は引き継がれる)。
    func end() {
        isActive = false
    }

    /// 案内を到達状態ごと捨てる。**地域パッケージが差し替わったときだけ**呼ぶ。
    /// 別の地域に移ったのなら、前の地域で到達したことは次の案内を止める理由にならない。
    func reset() {
        end()
        announcer.stop()
        polyline = []
        steps = []
        summary = nil
        narration = .initial
        stepIndex = 0
        progressM = 0
        hasArrived = false
    }
}
