import Testing

@testable import TendenkoDomain

/// 方位・長さ・勾配・フラグを指定できるエッジ。RoadGraph が逆向きを展開するので、
/// 経路を from→to の順に辿る限り bearingDeg はそのまま進行方向になる。
private func edge(_ from: Int64, _ to: Int64, bearing: Double, lengthM: Double = 100,
                  grade: Double = 0, flags: EdgeFlags = []) -> UndirectedEdge {
    UndirectedEdge(from: from, to: to, lengthM: lengthM, grade: grade,
                   bearingDeg: bearing, flags: flags)
}

/// `node` を分岐点にするための行き止まりの枝。
/// 曲がる案内は次数 3 以上の地点でしか出ないので、角を試すテストにはこれが要る。
private func branch(at node: Int64) -> UndirectedEdge {
    edge(node, 900 + node, bearing: 200)
}

/// ノード id を連番、座標は id をそのまま緯度に使った合成グラフ (座標自体は案内文に影響しない)。
private func graph(_ edges: [UndirectedEdge]) -> RoadGraph {
    var nodes: [Int64: GraphNode] = [:]
    for e in edges {
        nodes[e.from] = GraphNode(lat: 39.0 + Double(e.from) / 1000, lon: 141.9, elevM: nil)
        nodes[e.to] = GraphNode(lat: 39.0 + Double(e.to) / 1000, lon: 141.9, elevM: nil)
    }
    return RoadGraph(nodes: nodes, undirectedEdges: edges)
}

private func route(_ ids: [Int64], lengthM: Double = 0) -> Route {
    Route(nodeIDs: ids, cost: 0, lengthM: lengthM)
}

private let shelter = Shelter(name: "鵜住居小学校", point: GeoPoint(lat: 39.3, lon: 141.9), elevM: 20)

/// 指示 (Maneuver) だけを取り出す。文言のゆらぎに影響されず構造を検証するため。
private func maneuvers(_ steps: [GuidanceStep]) -> [Maneuver] {
    steps.map(\.maneuver)
}

@Suite("GuidanceScript — 経路から音声案内文を組み立てる (FR-13)")
struct GuidanceScriptTests {

    // MARK: - どこで案内するか

    @Test("直進だけの経路は出発と到達しか案内しない")
    func straightRouteOnlyStartAndArrive() {
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 0), edge(3, 4, bearing: 0)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3, 4]), in: g, destination: shelter)
        #expect(maneuvers(steps) == [.start(bearingDeg: 0), .arrive(shelterName: "鵜住居小学校")])
    }

    @Test("分岐の無い道の途中では曲がる案内をしない (道なりのカーブ)")
    func curveWithoutJunctionStaysSilent() {
        // OSM の道路はポリラインなので、直線の道でもノードごとに方位が変わる。
        // 行き先を選べない地点で「やや右」と言うのはノイズにしかならない
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 40)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(maneuvers(steps) == [.start(bearingDeg: 0), .arrive(shelterName: nil)])
    }

    @Test("分岐点で右に 90 度曲がる角を案内する")
    func rightTurn() {
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 90), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: shelter)
        #expect(maneuvers(steps) == [.start(bearingDeg: 0), .turn(.right), .arrive(shelterName: "鵜住居小学校")])
        #expect(steps[1].nodeID == 2) // 曲がる地点で発話する
    }

    @Test("分岐点で左に 90 度曲がる角を案内する")
    func leftTurn() {
        let g = graph([edge(1, 2, bearing: 90), edge(2, 3, bearing: 0), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: shelter)
        #expect(maneuvers(steps)[1] == .turn(.left))
    }

    @Test("方位が 0 度をまたぐ左折を正しく判定する")
    func leftTurnAcrossNorth() {
        // 北北東 (20°) から西北西 (290°) へ = 左に 90 度。単純な引き算では +270 になる
        let g = graph([edge(1, 2, bearing: 20), edge(2, 3, bearing: 290), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: shelter)
        #expect(maneuvers(steps)[1] == .turn(.left))
    }

    @Test("浅い角度は「やや右 / やや左」として案内する")
    func slightTurns() {
        let right = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 30), branch(at: 2)])
        #expect(maneuvers(GuidanceScript.steps(for: route([1, 2, 3]), in: right, destination: nil))[1]
                == .turn(.slightRight))

        let left = graph([edge(1, 2, bearing: 30), edge(2, 3, bearing: 0), branch(at: 2)])
        #expect(maneuvers(GuidanceScript.steps(for: route([1, 2, 3]), in: left, destination: nil))[1]
                == .turn(.slightLeft))
    }

    @Test("分岐点でも直進とみなす閾値未満の方位変化では案内しない")
    func straightThresholdKeepsSilent() {
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 19), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(maneuvers(steps) == [.start(bearingDeg: 0), .arrive(shelterName: nil)])
    }

    @Test("180 度近い転換は折り返し (九十九折り) として案内する")
    func sharpTurn() {
        // EvacuationRouter は来た道への即折り返しを展開しないので、これは別の道への
        // ヘアピン。「後ろへ引き返す」ではなく折り返して進む方向を伝える
        let right = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 175), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: right, destination: nil)
        #expect(maneuvers(steps)[1] == .turn(.sharpRight))
        #expect(steps[1].text.contains("折り返す"))
        #expect(steps[1].text.contains("右"))

        let left = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 185), branch(at: 2)])
        #expect(maneuvers(GuidanceScript.steps(for: route([1, 2, 3]), in: left, destination: nil))[1]
                == .turn(.sharpLeft))
    }

    @Test("階段に入る地点は分岐点でなくても案内する (足元の話なので選択の余地と無関係)")
    func stepsAhead() {
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 0, flags: .steps)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(maneuvers(steps) == [.start(bearingDeg: 0), .steps, .arrive(shelterName: nil)])
        #expect(steps[1].nodeID == 2)
    }

    @Test("階段が続いても案内は入口の 1 回だけ")
    func stepsAnnouncedOnce() {
        let g = graph([edge(1, 2, bearing: 0),
                       edge(2, 3, bearing: 0, flags: .steps),
                       edge(3, 4, bearing: 0, flags: .steps)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3, 4]), in: g, destination: nil)
        #expect(maneuvers(steps).filter { $0 == .steps }.count == 1)
    }

    @Test("十分な長さの上り坂に入る地点で坂を案内する")
    func climbAhead() {
        // grade 0.08 が 100m 続く (minClimbLengthM = 30 を超える)
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 0, grade: 0.08)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(maneuvers(steps) == [.start(bearingDeg: 0), .climb, .arrive(shelterName: nil)])
    }

    @Test("短すぎる起伏では坂を案内しない")
    func shortClimbIsIgnored() {
        // minClimbLengthM = 30 に満たない 10m の上り
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 0, lengthM: 10, grade: 0.08)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(!maneuvers(steps).contains(.climb))
    }

    @Test("下り坂は案内しない (登る指示だけを出す)")
    func downhillIsNotClimb() {
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 0, grade: -0.08)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(!maneuvers(steps).contains(.climb))
    }

    @Test("曲がりと階段が重なる地点では曲がる方向を優先する")
    func turnWinsOverSteps() {
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 90, flags: .steps), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(maneuvers(steps) == [.start(bearingDeg: 0), .turn(.right), .arrive(shelterName: nil)])
    }

    // MARK: - 距離

    @Test("直進が続く区間は次の指示までの距離にまとめる")
    func distanceAccumulatesOverStraightSegments() {
        let g = graph([edge(1, 2, bearing: 0, lengthM: 100),
                       edge(2, 3, bearing: 0, lengthM: 100),
                       edge(3, 4, bearing: 0, lengthM: 100),
                       edge(4, 5, bearing: 90, lengthM: 50),
                       branch(at: 4)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3, 4, 5]), in: g, destination: nil)
        #expect(maneuvers(steps) == [.start(bearingDeg: 0), .turn(.right), .arrive(shelterName: nil)])
        #expect(steps[1].distanceFromPreviousM == 300) // 曲がるまで 300m
        #expect(steps[2].distanceFromPreviousM == 50)  // 曲がってから到達まで 50m
        #expect(steps[1].text.contains("300メートル"))
    }

    @Test("出発地点の距離は 0")
    func startHasNoDistance() {
        let g = graph([edge(1, 2, bearing: 0)])
        let steps = GuidanceScript.steps(for: route([1, 2]), in: g, destination: nil)
        #expect(steps[0].distanceFromPreviousM == 0)
    }

    @Test("100m 未満の距離は 10m 単位に丸めて読み上げる")
    func shortDistanceRoundsToTen() {
        let g = graph([edge(1, 2, bearing: 0, lengthM: 42),
                       edge(2, 3, bearing: 90, lengthM: 10), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(steps[1].text.contains("40メートル")) // 42 → 40
    }

    @Test("100m 以上の距離は 50m 単位に丸めて読み上げる")
    func longDistanceRoundsToFifty() {
        let g = graph([edge(1, 2, bearing: 0, lengthM: 337),
                       edge(2, 3, bearing: 90, lengthM: 10), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(steps[1].text.contains("350メートル")) // 337 → 350
    }

    @Test("1km 以上はメートルではなくキロで読み上げる")
    func longDistanceUsesKilometers() {
        // 「3000メートル」は数字が大きすぎて耳で距離感に変換できない
        let g = graph([edge(1, 2, bearing: 0, lengthM: 3000),
                       edge(2, 3, bearing: 90, lengthM: 10), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(steps[1].text.contains("3キロ"))
        #expect(!steps[1].text.contains("メートル"))
    }

    @Test("キロは 0.1 刻みで読み、小数点以下が 0 なら整数で読む")
    func kilometerRounding() {
        #expect(GuidanceScript.summary(for: route([1], lengthM: 5479), destination: nil)
            .contains("5.5キロ"))
        #expect(GuidanceScript.summary(for: route([1], lengthM: 1950), destination: nil)
            .contains("2キロ"))
        #expect(GuidanceScript.summary(for: route([1], lengthM: 1234), destination: nil)
            .contains("1.2キロ"))
    }

    @Test("1km 未満はメートルのまま読む (境界)")
    func belowOneKilometerStaysMeters() {
        #expect(GuidanceScript.summary(for: route([1], lengthM: 950), destination: nil)
            .contains("950メートル"))
        #expect(GuidanceScript.summary(for: route([1], lengthM: 1000), destination: nil)
            .contains("1キロ"))
    }

    @Test("丸めて 0 になる距離は読み上げから省く")
    func negligibleDistanceOmitted() {
        // 3m 進んですぐ曲がる。「3メートル進んで」は案内として無意味
        let g = graph([edge(1, 2, bearing: 0, lengthM: 3),
                       edge(2, 3, bearing: 90, lengthM: 10), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(!steps[1].text.contains("メートル"))
        #expect(steps[1].text.contains("右"))
    }

    // MARK: - 文言

    @Test("出発は 8 方位の日本語で案内する")
    func startUsesCompassName() {
        let cases: [(Double, String)] = [
            (0, "北"), (45, "北東"), (90, "東"), (135, "南東"),
            (180, "南"), (225, "南西"), (270, "西"), (315, "北西"),
        ]
        for (bearing, name) in cases {
            let g = graph([edge(1, 2, bearing: bearing)])
            let steps = GuidanceScript.steps(for: route([1, 2]), in: g, destination: nil)
            // 「北」が「北東」に、「東」が「南東」に一致してしまわないよう先頭で照合する
            #expect(steps[0].text.hasPrefix(name + "に向かって"), "bearing \(bearing) は「\(name)」")
        }
    }

    @Test("方位は最も近い 8 方位に丸める")
    func compassRoundsToNearest() {
        let g = graph([edge(1, 2, bearing: 20)]) // 北東 (45) より北 (0) に近い
        #expect(GuidanceScript.steps(for: route([1, 2]), in: g, destination: nil)[0]
            .text.hasPrefix("北に向かって"))

        let ne = graph([edge(1, 2, bearing: 30)]) // 北 (0) より北東 (45) に近い
        #expect(GuidanceScript.steps(for: route([1, 2]), in: ne, destination: nil)[0]
            .text.hasPrefix("北東に向かって"))

        let n = graph([edge(1, 2, bearing: 350)]) // 0 度をまたいで北
        #expect(GuidanceScript.steps(for: route([1, 2]), in: n, destination: nil)[0]
            .text.hasPrefix("北に向かって"))
    }

    @Test("到達案内に避難場所の名前を入れる")
    func arriveNamesShelter() {
        let g = graph([edge(1, 2, bearing: 0)])
        let steps = GuidanceScript.steps(for: route([1, 2]), in: g, destination: shelter)
        #expect(steps.last!.text.contains("鵜住居小学校"))
        #expect(steps.last!.text.contains("留まって")) // FR-16: 到達後はその場に留まる
    }

    @Test("避難場所が分からない場合も到達を案内する (縮退)")
    func arriveWithoutShelterName() {
        let g = graph([edge(1, 2, bearing: 0)])
        let steps = GuidanceScript.steps(for: route([1, 2]), in: g, destination: nil)
        #expect(maneuvers(steps).last == .arrive(shelterName: nil))
        #expect(steps.last!.text.contains("避難場所"))
    }

    @Test("曲がる案内は方向を言葉で含む")
    func turnTextMentionsDirection() {
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 90), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(steps[1].text.contains("右"))
    }

    // MARK: - 縮退・境界

    @Test("既に避難場所にいる経路は到達だけを案内する")
    func alreadyAtShelter() {
        // EvacuationRouter は start が goal のとき nodeIDs = [start] を返す
        let g = graph([edge(1, 2, bearing: 0)])
        let steps = GuidanceScript.steps(for: route([1]), in: g, destination: shelter)
        #expect(maneuvers(steps) == [.arrive(shelterName: "鵜住居小学校")])
        #expect(steps[0].distanceFromPreviousM == 0)
        #expect(steps[0].nodeID == 1)
    }

    @Test("空の経路は案内を生成しない")
    func emptyRoute() {
        let g = graph([edge(1, 2, bearing: 0)])
        #expect(GuidanceScript.steps(for: route([]), in: g, destination: shelter).isEmpty)
    }

    @Test("グラフに無いノードを含む経路でも落ちない")
    func routeWithUnknownNodes() {
        let g = graph([edge(1, 2, bearing: 0)])
        let steps = GuidanceScript.steps(for: route([1, 2, 99]), in: g, destination: shelter)
        // 2→99 のエッジは引けないので、辿れた範囲で案内を組み立てる
        #expect(!steps.isEmpty)
        #expect(maneuvers(steps).last == .arrive(shelterName: "鵜住居小学校"))
    }

    @Test("辿れるエッジが 1 本も無ければ案内を生成しない")
    func noResolvableEdges() {
        let g = graph([edge(1, 2, bearing: 0)])
        #expect(GuidanceScript.steps(for: route([50, 51]), in: g, destination: shelter).isEmpty)
    }

    @Test("発話地点の座標をグラフから引く")
    func stepCarriesCoordinate() {
        let g = graph([edge(1, 2, bearing: 0), edge(2, 3, bearing: 90), branch(at: 2)])
        let steps = GuidanceScript.steps(for: route([1, 2, 3]), in: g, destination: nil)
        #expect(steps[1].point == GeoPoint(lat: 39.002, lon: 141.9))
    }

    // MARK: - 実データで起きた問題の回帰テスト

    @Test("道なりのカーブが続いても案内が増えない (釜石の実データで過剰だった件)")
    func windingRoadDoesNotFloodInstructions() {
        // 分岐の無い 20 ノードの蛇行路。ノードごとに ±30 度揺れる
        var edges: [UndirectedEdge] = []
        for i in Int64(1)..<20 {
            edges.append(edge(i, i + 1, bearing: i % 2 == 0 ? 30 : 0, lengthM: 50))
        }
        let steps = GuidanceScript.steps(for: route(Array(Int64(1)...20)), in: graph(edges),
                                         destination: shelter)
        #expect(maneuvers(steps) == [.start(bearingDeg: 0), .arrive(shelterName: "鵜住居小学校")])
    }

    // MARK: - 概要

    @Test("概要は避難場所名とおおよその距離を含む")
    func summaryMentionsShelterAndDistance() {
        let text = GuidanceScript.summary(for: route([1, 2], lengthM: 480), destination: shelter)
        #expect(text.contains("鵜住居小学校"))
        #expect(text.contains("500メートル")) // 480 → 50m 単位で 500
    }

    @Test("避難場所が分からない場合の概要も距離は伝える")
    func summaryWithoutShelterName() {
        let text = GuidanceScript.summary(for: route([1, 2], lengthM: 120), destination: nil)
        #expect(text.contains("避難場所"))
        #expect(text.contains("100メートル"))
    }
}
