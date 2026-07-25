/// ローリングキャッシュの保持/退避計画 (ADR-0004)。
///
/// 現在地メッシュと登録地点 (FR-05) の 3×3 を「必ず持つべき集合 (desired)」とし、
/// キャッシュ予算を超えた分を LRU で退避する計画を返す。
/// I/O を一切しない純粋関数なのでドメイン層に置き、TDD する。
/// 実際の DL・削除は Storage 層の RegionPackageStore が担う。
public enum CachePlanner {
    /// - Parameters:
    ///   - current: 現在地が属する 2 次メッシュ
    ///   - registered: 登録地点のメッシュ (FR-05)。各点の 3×3 も desired に加える
    ///   - cached: いま端末が持っているメッシュ。**LRU 順 (先頭がもっとも古い)**
    ///   - budgetCount: キャッシュに保持するメッシュ数の上限
    /// - Returns: DL すべき / 退避すべき / そのまま残すメッシュの計画
    public static func plan(
        current: MeshCode,
        registered: [MeshCode] = [],
        cached: [MeshCode],
        budgetCount: Int
    ) -> CachePlan {
        var desired = Set(current.neighborhood())
        for point in registered {
            desired.formUnion(point.neighborhood())
        }

        let cachedSet = Set(cached)
        let toFetch = desired.subtracting(cachedSet)
        let keep = desired.intersection(cachedSet)

        // desired は絶対に退避しない。退避候補は「持っているが desired でない」もの。
        // cached の LRU 順を保ったまま古い順に並ぶ。
        let evictable = cached.filter { !desired.contains($0) }

        // DL 後の総数 = desired 全部 + 退避しなかった非 desired。
        // これを budgetCount 以下にするために古い方から必要数だけ退避する。
        let overflow = desired.count + evictable.count - budgetCount
        let evictCount = max(0, min(overflow, evictable.count))
        let toEvict = Array(evictable.prefix(evictCount))

        return CachePlan(
            toFetch: toFetch.sorted { $0.code < $1.code },
            toEvict: toEvict,
            keep: keep.sorted { $0.code < $1.code })
    }
}

/// CachePlanner が返す計画。
public struct CachePlan: Equatable, Sendable {
    /// desired だが未取得 — DL 対象。
    public let toFetch: [MeshCode]
    /// 予算超過で退避する非 desired メッシュ (古い順)。
    public let toEvict: [MeshCode]
    /// desired かつ取得済み — そのまま残す。
    public let keep: [MeshCode]

    public init(toFetch: [MeshCode], toEvict: [MeshCode], keep: [MeshCode]) {
        self.toFetch = toFetch
        self.toEvict = toEvict
        self.keep = keep
    }
}
