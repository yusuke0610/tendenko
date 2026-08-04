/// 現在地への追従の閾値 (FR-14 / FR-16)。
/// `CostModel` / `GuidanceStyle` と同じ流儀で値として持ち、実データ・実機で調整できるようにする。
public struct TrackingStyle: Sendable {
    /// これを超えて経路から離れたら逸脱とみなす (m)。
    /// GPS の水平誤差と歩道の幅を見込む。小さくしすぎると誤差でリルートを繰り返す
    public var offRouteToleranceM: Double = 40
    /// 目的地にこれだけ近づいたら到達 (m)
    public var arrivalRadiusM: Double = 30

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

    public init(stepIndex: Int, offRouteDistanceM: Double, isOffRoute: Bool,
                hasArrived: Bool, distanceToNextStepM: Double?) {
        self.stepIndex = stepIndex
        self.offRouteDistanceM = offRouteDistanceM
        self.isOffRoute = isOffRoute
        self.hasArrived = hasArrived
        self.distanceToNextStepM = distanceToNextStepM
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
    public static func track(
        location: GeoPoint,
        steps: [GuidanceStep],
        polyline: [GeoPoint],
        fromStepIndex: Int = 0,
        style: TrackingStyle = TrackingStyle()
    ) -> TrackingState {
        let offRouteDistanceM = RouteGeometry.distanceToPolylineM(location, polyline: polyline)

        // 到達判定は最後の指示 (到着案内) の地点で見る
        let hasArrived = steps.last.map {
            location.distanceM(to: $0.point) <= style.arrivalRadiusM
        } ?? false

        // 通過済みの指示を進める。判定は案内地点との直線距離ではなく**経路上の道なり距離**で行う。
        // 直線距離だと、通り過ぎて遠ざかった指示が「近くない」ままなので進行が止まる。
        // **後戻りはしない** — 測位のふらつきで前の指示に戻ると同じ案内を繰り返し読み上げる。
        var index = min(max(fromStepIndex, 0), steps.count)
        if polyline.count > 1 {
            let traveled = RouteGeometry.progressAlongPolylineM(location, polyline: polyline)
            while index < steps.count,
                  RouteGeometry.progressAlongPolylineM(steps[index].point,
                                                       polyline: polyline) <= traveled {
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
                             distanceToNextStepM: distanceToNextStepM)
    }
}
