/// 追従結果 (`TrackingState`) から「今この瞬間に何を喋るか」を決める閾値 (FR-13/FR-14/FR-16)。
/// `GuidanceStyle` / `TrackingStyle` と同じ流儀で値として持ち、実データ・実機で調整できるようにする。
public struct NarrationStyle: Sendable {
    /// 進捗案内を出す残距離のしきい値 (m)。大きい順に 1 度ずつ読む。
    /// ADR-0007 の残課題「実データで 3,000m の無案内区間」はこれで埋める
    public var progressCuesM: [Double] = [1000, 500, 200]
    /// 進捗案内を出す最小の区間長 (m)。
    ///
    /// **都市部での案内過多を防ぐ要**。格子状の街路では分岐点が密で区間が短く、そこへ進捗案内を
    /// 重ねると「曲がる案内 → すぐ進捗案内 → また曲がる案内」と喋り続けることになる。
    /// 長い無案内区間を埋めるのが目的なので、短い区間では黙る
    public var minLegLengthForCueM: Double = 600
    /// 逸脱が続いている間にリルートを再試行する間隔 (秒)。
    ///
    /// 逸脱の立ち上がりだけでリルートすると、1 度目のリルートが同じ経路を返した場合
    /// (現在地がグラフから離れている等) に二度と再試行されず、逸脱したまま案内が止まる
    public var rerouteRetryIntervalS: Double = 10

    public init() {}
}

/// どこまで読み上げ済みかを持つ状態。呼び出し側が次の `next` にそのまま渡す。
///
/// 純粋関数で「同じ案内を 2 度読まない」を実現するために、進行の記憶を値として外に出している。
public struct NarrationState: Sendable, Equatable {
    /// 読み上げ済みの指示の位置 (`GuidanceScript.steps` のインデックス)。
    /// nil は「まだ何も読んでいない = 案内の開始前」
    public var announcedStepIndex: Int?
    /// 現在の区間で読み上げ済みの進捗しきい値 (m)。指示が進むたびに nil に戻る
    public var announcedCueM: Double?
    /// 前回の更新で経路を外れていたか。逸脱通知を立ち上がりでだけ読むために持つ
    public var wasOffRoute: Bool
    /// 到達を読み上げ済みか (FR-16)
    public var hasAnnouncedArrival: Bool
    /// 直近にリルートを要求した時刻 (呼び出し側が渡す単調増加の秒)。再試行の間隔に使う
    public var lastRerouteAt: Double?

    public init(announcedStepIndex: Int? = nil, announcedCueM: Double? = nil,
                wasOffRoute: Bool = false, hasAnnouncedArrival: Bool = false,
                lastRerouteAt: Double? = nil) {
        self.announcedStepIndex = announcedStepIndex
        self.announcedCueM = announcedCueM
        self.wasOffRoute = wasOffRoute
        self.hasAnnouncedArrival = hasAnnouncedArrival
        self.lastRerouteAt = lastRerouteAt
    }

    /// 案内の開始前。新しい経路を案内し始めるたびにここへ戻す
    public static let initial = NarrationState()
}

/// 1 回の更新で行うこと。
public struct Narration: Sendable, Equatable {
    /// 読み上げる文。順に発話する。空なら黙る
    public let texts: [String]
    /// 経路を引き直すべきか (FR-14)。実行は呼び出し側の責務
    public let needsReroute: Bool
    /// 次の `next` に渡す状態
    public let state: NarrationState

    public init(texts: [String], needsReroute: Bool, state: NarrationState) {
        self.texts = texts
        self.needsReroute = needsReroute
        self.state = state
    }
}

/// 追従結果を発話に変換する純粋関数 (FR-13 / FR-14 / FR-16)。
///
/// 測位・発話・リルートの実行はすべて呼び出し側 (UI 層) の責務で、ここは
/// 「今何を言うべきか」「経路を引き直すべきか」だけを決める。時刻すら引数で受け取り、
/// `make domain-test` でシミュレータなしに全分岐を固定できるようにしている。
public enum GuidanceNarration {

    /// - Parameters:
    ///   - tracking: `RouteTracker.track` の結果
    ///   - steps: 追従中の経路の `GuidanceScript.steps`
    ///   - summary: `GuidanceScript.summary`。案内の開始時に一度だけ読む
    ///   - previous: 前回の `Narration.state` (初回は `.initial`)
    ///   - now: 単調増加の秒。リルート再試行の間隔にだけ使う
    public static func next(
        tracking: TrackingState,
        steps: [GuidanceStep],
        summary: String?,
        previous: NarrationState,
        now: Double,
        style: NarrationStyle = NarrationStyle()
    ) -> Narration {
        var state = previous
        guard !steps.isEmpty else {
            return Narration(texts: [], needsReroute: false, state: state)
        }

        // 1. 到達はすべてに優先する (FR-16)。着いた後は逸脱も進捗も意味を持たない
        if tracking.hasArrived {
            state.wasOffRoute = tracking.isOffRoute
            guard !state.hasAnnouncedArrival else {
                return Narration(texts: [], needsReroute: false, state: state)
            }
            state.hasAnnouncedArrival = true
            return Narration(texts: [GuidanceScript.arrivedText(shelterName: shelterName(of: steps))],
                             needsReroute: false, state: state)
        }

        // 2. 案内の開始。**ここでは逸脱を判定しない。**
        // 経路は今この現在地から引かれたばかりで、始点のノードが遠い (グラフの粗い山間部など)
        // だけで「開始と同時に逸脱 → 同じ経路へリルート」を繰り返すことになる。
        // 立ち上がりの基準として現在の逸脱状態を記録するに留める
        if state.announcedStepIndex == nil {
            state.announcedStepIndex = tracking.stepIndex
            state.announcedCueM = nil
            state.wasOffRoute = tracking.isOffRoute
            return Narration(texts: openingTexts(steps: steps, summary: summary,
                                                 stepIndex: tracking.stepIndex),
                             needsReroute: false, state: state)
        }

        // 3. 逸脱 (FR-14)。外れている間の指示は既に現在地と無関係なので、進行も進捗も読まない
        if tracking.isOffRoute {
            let rising = !previous.wasOffRoute
            let retryDue = (now - (previous.lastRerouteAt ?? -Double.infinity)) >= style.rerouteRetryIntervalS
            state.wasOffRoute = true
            guard rising || retryDue else {
                return Narration(texts: [], needsReroute: false, state: state)
            }
            state.lastRerouteAt = now
            // 通知は立ち上がりで 1 度だけ。再試行のたびに読み上げると、外れている間ずっと喋り続ける
            return Narration(texts: rising ? [GuidanceScript.offRouteText()] : [],
                             needsReroute: true, state: state)
        }
        state.wasOffRoute = false

        // 4. 指示が進んだ。**次に来る指示**を読む。
        // `TrackingState.stepIndex` は「次に案内すべき指示」であり、その `distanceFromPreviousM` は
        // 直前の案内地点からの距離。通過した瞬間に読むと「300メートル先、右に曲がります」になる
        let announced = state.announcedStepIndex ?? 0
        if tracking.stepIndex > announced {
            state.announcedStepIndex = tracking.stepIndex
            state.announcedCueM = nil
            guard tracking.stepIndex < steps.count else {
                return Narration(texts: [], needsReroute: false, state: state)
            }
            return Narration(texts: [steps[tracking.stepIndex].text],
                             needsReroute: false, state: state)
        }

        // 5. 進捗案内。長い直進区間で黙り続けないための補い (ADR-0007 の残課題)
        if let cue = progressCue(tracking: tracking, steps: steps, state: state, style: style) {
            state.announcedCueM = cue.threshold
            return Narration(texts: [cue.text], needsReroute: false, state: state)
        }

        return Narration(texts: [], needsReroute: false, state: state)
    }

    // MARK: - 内訳

    /// 案内の開始で読む一式: 概要 → 歩き出す方向 → 次の指示。
    ///
    /// 歩き出す方向 (`steps[0]`) は追従上は通過済みでも必ず読む。
    /// 「どちらへ向かって歩き出すか」は最初に一度しか言われず、聞かずに始めると初手で迷う。
    private static func openingTexts(steps: [GuidanceStep], summary: String?,
                                     stepIndex: Int) -> [String] {
        var texts: [String] = []
        if let summary { texts.append(summary) }
        texts.append(steps[0].text)
        if stepIndex > 0, stepIndex < steps.count {
            texts.append(steps[stepIndex].text)
        }
        return texts
    }

    /// 到達文に使う避難場所名。末尾の指示が到達案内なら、そこに載っている名前を使う。
    private static func shelterName(of steps: [GuidanceStep]) -> String? {
        guard let maneuver = steps.last?.maneuver,
              case .arrive(let name) = maneuver else { return nil }
        return name
    }

    /// 残距離がしきい値を下回ったら、**同じ指示を残距離で読み直す**。
    ///
    /// 文言を新造せず `GuidanceScript.text(for:distanceM:)` を残距離で呼び直すのは、
    /// 同じ角を進捗と案内地点で違う言い回しにしないため。カーナビと同じ形になる
    /// (「500メートル先、右に曲がります」→「200メートル先、右に曲がります」)。
    private static func progressCue(tracking: TrackingState, steps: [GuidanceStep],
                                    state: NarrationState,
                                    style: NarrationStyle) -> (threshold: Double, text: String)? {
        guard tracking.stepIndex < steps.count,
              let remainingM = tracking.distanceToNextStepM else { return nil }
        let step = steps[tracking.stepIndex]
        // 短い区間では出さない (都市部の案内過多を防ぐ)
        guard step.distanceFromPreviousM >= style.minLegLengthForCueM else { return nil }

        // 未読のうち最も小さいしきい値まで一気に飛ばす (バックグラウンド復帰などで大きく進んだ場合)
        let candidate = style.progressCuesM.filter { threshold in
            // 区間より長いしきい値は意味を持たない (区間の頭で即座に読むことになる)
            threshold < step.distanceFromPreviousM
                && remainingM <= threshold
                && (state.announcedCueM.map { threshold < $0 } ?? true)
        }.min()
        guard let threshold = candidate else { return nil }
        return (threshold, GuidanceScript.text(for: step.maneuver, distanceM: remainingM))
    }
}
