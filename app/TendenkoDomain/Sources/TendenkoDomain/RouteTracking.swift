/// 現在地への追従の閾値 (FR-14 / FR-16)。
/// `CostModel` / `GuidanceStyle` と同じ流儀で値として持ち、実データ・実機で調整できるようにする。
public struct TrackingStyle: Sendable {
    /// これを超えて経路から離れたら逸脱とみなす (m)。
    /// GPS の水平誤差と歩道の幅を見込む。小さくしすぎると誤差でリルートを繰り返す
    public var offRouteToleranceM: Double = 40
    /// 目的地にこれだけ近づいたら到達 (m)
    public var arrivalRadiusM: Double = 30
    /// 進行を探す範囲 (m)。前回の進行位置からこの距離だけ前方の区間だけを候補にする。
    /// 歩行速度 (1.5m/s 前後) に対して十分広く、九十九折りの折り返し間隔よりは狭い値にする
    public var progressWindowM: Double = 150

    public init() {}
}

/// 現在地に対する案内の進行状況。
public struct TrackingState: Sendable, Equatable {
    /// 次に案内すべき指示の位置 (`GuidanceScript.steps` のインデックス)。
    /// すべて通過し終えると `steps.count` になる
    public let stepIndex: Int
    /// 経路からの最短距離 (m)
    public let offRouteDistanceM: Double
    /// 経路を外れているか (FR-14: リルートの起点)
    public let isOffRoute: Bool
    /// 目的地に到達したか (FR-16)
    public let hasArrived: Bool
    /// 次の案内地点までの残距離 (m)。次が無ければ nil。
    /// 区間が長いときの進捗案内 (「あと◯◯メートル」) に使える
    public let distanceToNextStepM: Double?
    /// 経路上に射影した現在地の、経路始点からの道なり距離 (m)。
    /// **次の更新でそのまま `fromProgressM` に渡す** — 進行を探す範囲をここから決める
    public let progressM: Double

    public init(stepIndex: Int, offRouteDistanceM: Double, isOffRoute: Bool,
                hasArrived: Bool, distanceToNextStepM: Double?, progressM: Double) {
        self.stepIndex = stepIndex
        self.offRouteDistanceM = offRouteDistanceM
        self.isOffRoute = isOffRoute
        self.hasArrived = hasArrived
        self.distanceToNextStepM = distanceToNextStepM
        self.progressM = progressM
    }
}

/// 現在地を案内に突き合わせる純粋関数 (FR-14 / FR-16)。
///
/// 位置の取得 (Core Location) とリルートの実行 (`EvacuationRouter` の再実行)、発話は呼び出し側の
/// 責務で、ここは「今どこまで進んでいて、外れていないか、着いたか」だけを判定する。
public enum RouteTracker {

    /// - Parameters:
    ///   - steps: `GuidanceScript.steps` の結果
    ///   - polyline: `RouteGeometry.polyline` の結果 (逸脱判定に使う)
    ///   - fromStepIndex: 前回の `stepIndex`。ここより手前には戻さない
    ///   - fromProgressM: 前回の `progressM`。ここから前方の区間だけで進行を探す
    public static func track(
        location: GeoPoint,
        steps: [GuidanceStep],
        polyline: [GeoPoint],
        fromStepIndex: Int = 0,
        fromProgressM: Double = 0,
        style: TrackingStyle = TrackingStyle()
    ) -> TrackingState {
        // 逸脱判定は経路全体との最短距離で見る。窓に絞ると、窓の外の区間を歩いている限り
        // 「経路上にいるのに逸脱」と誤判定してリルートを繰り返す
        let nearest = RouteGeometry.project(location, onto: polyline)
        let offRouteDistanceM = nearest?.distanceM ?? .infinity

        // 到達判定は最後の指示 (到着案内) の地点で見る
        let hasArrived = steps.last.map {
            location.distanceM(to: $0.point) <= style.arrivalRadiusM
        } ?? false

        let traveled = progressM(of: location, polyline: polyline, from: fromProgressM,
                                 nearest: nearest, style: style)

        // 通過済みの指示を進める。判定は案内地点との直線距離ではなく**経路上の道なり距離**で行う。
        // 直線距離だと、通り過ぎて遠ざかった指示が「近くない」ままなので進行が止まる。
        // **後戻りはしない** — 測位のふらつきで前の指示に戻ると同じ案内を繰り返し読み上げる。
        var index = min(max(fromStepIndex, 0), steps.count)
        if polyline.count > 1 {
            let stepProgress = progressOfSteps(steps, polyline: polyline)
            while index < steps.count, stepProgress[index] <= traveled {
                index += 1
            }
        }

        let distanceToNextStepM = index < steps.count
            ? location.distanceM(to: steps[index].point)
            : nil

        return TrackingState(stepIndex: index,
                             offRouteDistanceM: offRouteDistanceM,
                             isOffRoute: offRouteDistanceM > style.offRouteToleranceM,
                             hasArrived: hasArrived,
                             distanceToNextStepM: distanceToNextStepM,
                             progressM: traveled)
    }

    /// 現在地の道なり距離。前回位置から前方 `progressWindowM` の範囲だけを候補にする。
    ///
    /// 経路全体の最近傍を採ると、九十九折り (`GuidanceScript` が sharp として案内するとおり、
    /// 高台へ登る経路では普通に現れる) や並走路で、GPS 誤差により折り返した先の区間のほうが
    /// 近くなる。そのまま進行に採ると間の指示をまとめて飛ばしてしまう。
    ///
    /// ただし窓の中に**許容幅以内の区間が無ければ**全体の最近傍に戻す。バックグラウンド復帰などで
    /// 大きく進んだ場合に、経路上にいるのに進行が窓の縁で止まって案内が動かなくなるのを防ぐ。
    private static func progressM(of location: GeoPoint, polyline: [GeoPoint],
                                  from fromProgressM: Double,
                                  nearest: RouteGeometry.Projection?,
                                  style: TrackingStyle) -> Double {
        let previous = max(fromProgressM, 0)
        let window = previous...(previous + style.progressWindowM)
        if let windowed = RouteGeometry.project(location, onto: polyline, searchRangeM: window),
           windowed.distanceM <= style.offRouteToleranceM {
            return windowed.progressM
        }
        return nearest?.progressM ?? 0
    }

    /// 各案内地点の道なり距離 (m)。案内は経路の順に並ぶので、頂点を前から順に消費して対応付ける。
    /// 案内地点ごとに経路全体を探すと、自己交差や並走区間で別の区間の頂点に対応づき順序が壊れる。
    private static func progressOfSteps(_ steps: [GuidanceStep],
                                        polyline: [GeoPoint]) -> [Double] {
        guard !polyline.isEmpty else { return Array(repeating: 0, count: steps.count) }

        let cumulative = RouteGeometry.cumulativeDistancesM(polyline)
        var out: [Double] = []
        out.reserveCapacity(steps.count)
        var cursor = 0
        for step in steps {
            var bestIndex = cursor
            var bestDistance = Double.infinity
            for i in cursor..<polyline.count {
                let d = step.point.distanceM(to: polyline[i])
                if d < bestDistance {
                    bestDistance = d
                    bestIndex = i
                }
            }
            out.append(cumulative[bestIndex])
            cursor = bestIndex
        }
        return out
    }
}
