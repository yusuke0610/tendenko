/// 曲がる方向。
///
/// U ターンが無いのは `EvacuationRouter` が来た道への即折り返しを展開しないため
/// (`if e.to == s.key.from { continue }`)。180 度近い転換は必ず「別の道への折り返し」＝
/// 九十九折り・ヘアピンであり、高台へ登る経路では正常な形なので sharp として案内する。
public enum TurnDirection: Sendable, Equatable {
    case slightLeft
    case left
    case sharpLeft
    case slightRight
    case right
    case sharpRight
}

/// 案内地点でユーザーに求める行動 (ADR-0007)。
public enum Maneuver: Sendable, Equatable {
    /// 歩き出す方向 (8 方位で読み上げる)
    case start(bearingDeg: Double)
    case turn(TurnDirection)
    /// これから続く上り坂を登り切る
    case climb
    /// これから階段に入る
    case steps
    /// 避難場所への到達。名前が引けない場合は nil で縮退する
    case arrive(shelterName: String?)
}

/// 発話 1 回分の案内。`nodeID` は発話地点で、FR-14 (逸脱検知)・FR-16 (到達検知) の位置追従で使う。
public struct GuidanceStep: Sendable, Equatable {
    public let nodeID: Int64
    public let point: GeoPoint
    public let maneuver: Maneuver
    /// 直前の案内地点からここまでの実距離 (m)。丸めていない生の値
    public let distanceFromPreviousM: Double
    /// 読み上げ文
    public let text: String

    public init(nodeID: Int64, point: GeoPoint, maneuver: Maneuver,
                distanceFromPreviousM: Double, text: String) {
        self.nodeID = nodeID
        self.point = point
        self.maneuver = maneuver
        self.distanceFromPreviousM = distanceFromPreviousM
        self.text = text
    }
}

/// 案内の粒度を決める閾値 (ADR-0007)。実データを見ながら調整できるよう値で持つ。
///
/// `CostModel.turnThresholdDeg` とは意図的に別に持つ。探索の「曲がりにくさにペナルティをかけるか」と
/// 案内の「曲がったと言うべきか」は別の問題で、片方の調整がもう片方に漏れてはいけない。
public struct GuidanceStyle: Sendable {
    /// これ未満の方位変化は直進とみなし、発話しない
    public var straightThresholdDeg: Double = 20
    /// これ未満は「やや右 / やや左」、これ以上は「右 / 左」
    public var turnThresholdDeg: Double = 50
    /// これ以上は折り返し (九十九折り・ヘアピン)
    public var sharpThresholdDeg: Double = 150
    /// 曲がる案内を出す分岐点の最小次数。2 は「道の途中」なので 3 以上を分岐とみなす
    public var junctionDegree: Int = 3
    /// これ以上の勾配を上り坂とみなす
    public var climbGrade: Double = 0.05
    /// 上り坂として案内する最小の連続長 (m)。短い起伏で喋らない
    public var minClimbLengthM: Double = 30
    /// これ未満の距離は fineStepM 単位、以上は coarseStepM 単位に丸めて読み上げる
    public var coarseDistanceM: Double = 100
    public var fineStepM: Double = 10
    public var coarseStepM: Double = 50
    /// これ以上はメートルではなくキロで読み上げる。「3000メートル」は耳で捉えにくい
    public var kilometerThresholdM: Double = 1000

    public init() {}
}

/// 経路 (`Route`) と道路グラフから音声案内文を組み立てる純粋関数 (FR-13、ADR-0007)。
///
/// 発話するのは「次の行動が変わる地点」だけで、直進中は黙る。情報量を増やすことではなく、
/// 曲がる・登る・階段・到達だけを言うことが「画面を見ずに完走できる粒度」だという判断による。
public enum GuidanceScript {

    /// 経路上の案内を先頭 (出発) から末尾 (到達) まで順に返す。
    /// 経路が辿れない場合は空を返す (発話しないだけで、地図表示は継続できる)。
    public static func steps(
        for route: Route,
        in graph: RoadGraph,
        destination: Shelter?,
        style: GuidanceStyle = GuidanceStyle()
    ) -> [GuidanceStep] {
        let legs = resolveLegs(route.nodeIDs, in: graph)

        guard let first = legs.first else {
            // 既に避難場所にいる (EvacuationRouter が nodeIDs = [start] を返すケース)
            if route.nodeIDs.count == 1, let id = route.nodeIDs[0] as Int64?,
               let point = point(of: id, in: graph) {
                return [arriveStep(nodeID: id, point: point, distanceM: 0,
                                   destination: destination, style: style)]
            }
            return []
        }

        var out: [GuidanceStep] = []
        if let point = point(of: first.from, in: graph) {
            let maneuver = Maneuver.start(bearingDeg: first.edge.bearingDeg)
            out.append(GuidanceStep(nodeID: first.from, point: point, maneuver: maneuver,
                                    distanceFromPreviousM: 0,
                                    text: text(for: maneuver, distanceM: 0, style: style)))
        }

        var accumulatedM = 0.0
        for i in legs.indices {
            accumulatedM += legs[i].edge.lengthM
            guard i + 1 < legs.count else { break }

            let nodeID = legs[i].to
            guard let maneuver = maneuverEntering(legs, at: i + 1, node: nodeID, in: graph,
                                                  style: style),
                  let point = point(of: nodeID, in: graph)
            else { continue }

            out.append(GuidanceStep(nodeID: nodeID, point: point, maneuver: maneuver,
                                    distanceFromPreviousM: accumulatedM,
                                    text: text(for: maneuver, distanceM: accumulatedM, style: style)))
            accumulatedM = 0
        }

        let last = legs[legs.count - 1].to
        if let point = point(of: last, in: graph) {
            out.append(arriveStep(nodeID: last, point: point, distanceM: accumulatedM,
                                  destination: destination, style: style))
        }
        return out
    }

    /// 案内開始時に一息で読む概要。経路の全長を伝えて心構えを作る。
    public static func summary(
        for route: Route,
        destination: Shelter?,
        style: GuidanceStyle = GuidanceStyle()
    ) -> String {
        let place = destination?.name ?? "避難場所"
        guard let distance = distanceText(route.lengthM, style: style) else {
            return "\(place)へ向かいます"
        }
        return "\(place)へ、およそ\(distance)です"
    }

    // MARK: - 経路の展開

    /// 経路上の 1 区間 (ノード間の移動)。
    private struct Leg {
        let from: Int64
        let to: Int64
        let edge: DirectedEdge
    }

    /// ノード列を隣接リストと突き合わせてエッジ列にする。
    /// 引けないノードに当たったらそこで打ち切る (辿れた範囲までは案内する)。
    private static func resolveLegs(_ nodeIDs: [Int64], in graph: RoadGraph) -> [Leg] {
        var legs: [Leg] = []
        for i in 0..<max(nodeIDs.count - 1, 0) {
            let from = nodeIDs[i], to = nodeIDs[i + 1]
            guard let edge = graph.adjacency[from]?.first(where: { $0.to == to }) else { break }
            legs.append(Leg(from: from, to: to, edge: edge))
        }
        return legs
    }

    /// グラフに座標が無いノードでは発話しない (region.sqlite の edges と nodes が食い違う異常系)。
    private static func point(of nodeID: Int64, in graph: RoadGraph) -> GeoPoint? {
        graph.nodes[nodeID].map { GeoPoint(lat: $0.lat, lon: $0.lon) }
    }

    // MARK: - 案内すべきことの判定

    /// `legs[index]` に入る地点で案内すべきことを返す。無ければ nil (＝黙って直進)。
    /// 優先順位は 曲がる > 階段 > 坂。迷わないことを最優先し、1 地点で 1 つだけ言う。
    private static func maneuverEntering(_ legs: [Leg], at index: Int, node nodeID: Int64,
                                         in graph: RoadGraph,
                                         style: GuidanceStyle) -> Maneuver? {
        let previous = legs[index - 1].edge
        let next = legs[index].edge

        // 曲がる案内は分岐点でだけ意味を持つ。OSM の道路はポリラインなので、道なりのカーブでも
        // ノードごとに方位が変わる。行き先を選べない地点 (次数 2) で「やや右」と言うのは
        // ノイズでしかなく、FR-13 の「画面を見ずに完走できる粒度」をむしろ壊す。
        if isJunction(nodeID, in: graph, style: style) {
            let delta = signedBearingDelta(from: previous.bearingDeg, to: next.bearingDeg)
            if let direction = turnDirection(delta, style: style) {
                return .turn(direction)
            }
        }
        // 階段・坂は「入る瞬間」だけ案内する。連続していても繰り返さない
        if next.flags.contains(.steps), !previous.flags.contains(.steps) {
            return .steps
        }
        if next.grade >= style.climbGrade, previous.grade < style.climbGrade,
           climbLengthM(from: index, in: legs, style: style) >= style.minClimbLengthM {
            return .climb
        }
        return nil
    }

    /// 行き先を選べる地点か。隣接ノードが 3 つ以上あれば分岐点とみなす。
    /// 道の途中 (次数 2) は道なりに進むしかないので案内しない。
    private static func isJunction(_ nodeID: Int64, in graph: RoadGraph,
                                   style: GuidanceStyle) -> Bool {
        (graph.adjacency[nodeID]?.count ?? 0) >= style.junctionDegree
    }

    /// 方位差を -180…180 に正規化する。正が右回り。0 度をまたぐ場合も正しく扱う。
    private static func signedBearingDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private static func turnDirection(_ delta: Double, style: GuidanceStyle) -> TurnDirection? {
        let magnitude = abs(delta)
        if magnitude < style.straightThresholdDeg { return nil }
        if magnitude >= style.sharpThresholdDeg { return delta > 0 ? .sharpRight : .sharpLeft }
        if magnitude < style.turnThresholdDeg { return delta > 0 ? .slightRight : .slightLeft }
        return delta > 0 ? .right : .left
    }

    /// `index` から連続する上り区間の合計長。短い起伏で「坂を登り切る」と言わないための判定に使う。
    private static func climbLengthM(from index: Int, in legs: [Leg],
                                     style: GuidanceStyle) -> Double {
        var total = 0.0
        var i = index
        while i < legs.count, legs[i].edge.grade >= style.climbGrade {
            total += legs[i].edge.lengthM
            i += 1
        }
        return total
    }

    // MARK: - 文言

    private static func arriveStep(nodeID: Int64, point: GeoPoint, distanceM: Double,
                                   destination: Shelter?, style: GuidanceStyle) -> GuidanceStep {
        let maneuver = Maneuver.arrive(shelterName: destination?.name)
        return GuidanceStep(nodeID: nodeID, point: point, maneuver: maneuver,
                            distanceFromPreviousM: distanceM,
                            text: text(for: maneuver, distanceM: distanceM, style: style))
    }

    private static func text(for maneuver: Maneuver, distanceM: Double,
                             style: GuidanceStyle) -> String {
        // カーナビと同じ「距離 → 動作」の語順にする。先に距離を言うほうが身構えられる
        let lead = distanceText(distanceM, style: style).map { "\($0)先、" } ?? "この先、"

        switch maneuver {
        case .start(let bearingDeg):
            return "\(compassName(bearingDeg))に向かって進んでください"
        case .turn(let direction):
            return lead + turnText(direction)
        case .climb:
            return lead + "上り坂が続きます。登り切ってください"
        case .steps:
            return lead + "階段を上ります"
        case .arrive(let shelterName):
            let place = shelterName ?? "避難場所"
            guard let distance = distanceText(distanceM, style: style) else {
                return "\(place)に到着しました。その場に留まってください"
            }
            return "\(distance)先、\(place)に到着します。到着したら、その場に留まってください"
        }
    }

    private static func turnText(_ direction: TurnDirection) -> String {
        switch direction {
        case .right: return "右に曲がります"
        case .left: return "左に曲がります"
        case .slightRight: return "右方向です"
        case .slightLeft: return "左方向です"
        case .sharpRight: return "折り返すように右です"
        case .sharpLeft: return "折り返すように左です"
        }
    }

    /// 音声で読み上げるための距離。丸めて 0 になる距離は言わない (「3メートル」は案内にならない)。
    /// 1km 以上はキロで読む — 「3000メートル」は数字が大きすぎて耳で距離感に変換できない。
    private static func distanceText(_ distanceM: Double, style: GuidanceStyle) -> String? {
        if distanceM >= style.kilometerThresholdM {
            let km = (distanceM / 100).rounded() / 10 // 0.1km 単位
            let value = km.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(km))
                : String(format: "%.1f", km)
            return value + "キロ"
        }
        let unit = distanceM < style.coarseDistanceM ? style.fineStepM : style.coarseStepM
        let rounded = (distanceM / unit).rounded() * unit
        guard rounded > 0 else { return nil }
        return "\(Int(rounded))メートル"
    }

    private static let compassNames = ["北", "北東", "東", "南東", "南", "南西", "西", "北西"]

    private static func compassName(_ bearingDeg: Double) -> String {
        var bearing = bearingDeg.truncatingRemainder(dividingBy: 360)
        if bearing < 0 { bearing += 360 }
        return compassNames[Int((bearing / 45).rounded()) % 8]
    }
}
