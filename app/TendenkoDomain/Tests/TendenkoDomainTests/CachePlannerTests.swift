import Testing

@testable import TendenkoDomain

@Suite("CachePlanner — ローリングキャッシュの保持/退避計画 (ADR-0004)")
struct CachePlannerTests {
    private func mesh(_ c: String) -> MeshCode { MeshCode(c)! }

    @Test("空キャッシュでは現在地の 3×3 を全部 DL 対象にする")
    func emptyCacheFetchesNeighborhood() {
        let plan = CachePlanner.plan(
            current: mesh("584177"), registered: [], cached: [], budgetCount: 32)
        #expect(Set(plan.toFetch) == Set(mesh("584177").neighborhood()))
        #expect(plan.toEvict.isEmpty)
        #expect(plan.keep.isEmpty)
    }

    @Test("desired が全て揃っていれば DL も退避もしない")
    func fullyCachedIsNoop() {
        let desired = mesh("584177").neighborhood()
        let plan = CachePlanner.plan(
            current: mesh("584177"), registered: [], cached: desired, budgetCount: 32)
        #expect(plan.toFetch.isEmpty)
        #expect(plan.toEvict.isEmpty)
        #expect(Set(plan.keep) == Set(desired))
    }

    @Test("登録地点の 3×3 も desired に加わる (現在地と和集合・重複なし)")
    func registeredPointsUnioned() {
        // 遠く離れた登録地点なので現在地の 3×3 と重ならない
        let plan = CachePlanner.plan(
            current: mesh("584177"), registered: [mesh("503324")], cached: [], budgetCount: 64)
        let expected = Set(mesh("584177").neighborhood()).union(mesh("503324").neighborhood())
        #expect(Set(plan.toFetch) == expected)
        #expect(expected.count == 18) // 9 + 9、重複なし
    }

    @Test("予算超過のとき desired 外のもっとも古いメッシュから退避する (LRU)")
    func evictsOldestNonDesiredOverBudget() {
        let desired = mesh("584177").neighborhood() // 9 個
        // desired 9 + 非 desired 3 = 12。budget 10 なら 2 個退避。
        // cached は LRU (先頭が最古)。非 desired の古い順に old1, old2, old3。
        let stale = [mesh("503324"), mesh("503325"), mesh("503326")]
        let cached = stale + desired // stale の方が古い
        let plan = CachePlanner.plan(
            current: mesh("584177"), registered: [], cached: cached, budgetCount: 10)
        #expect(plan.toFetch.isEmpty)
        #expect(plan.toEvict == [mesh("503324"), mesh("503325")]) // 最古 2 個・入力順
        #expect(Set(plan.keep) == Set(desired))
    }

    @Test("desired は cached 上で最古でも退避しない")
    func desiredNeverEvicted() {
        let desired = mesh("584177").neighborhood()
        // desired を最古に置き、新しい非 desired を大量に積んでも desired は残す
        let fresh = [mesh("503324"), mesh("503325")]
        let cached = desired + fresh // desired の方が古い
        let plan = CachePlanner.plan(
            current: mesh("584177"), registered: [], cached: cached, budgetCount: 9)
        // budget 9 < desired(9)+fresh(2)=11 → 非 desired の fresh 2 個を退避、desired は全部残す
        #expect(plan.toEvict == fresh)
        #expect(Set(plan.keep) == Set(desired))
        #expect(plan.toFetch.isEmpty)
    }

    @Test("予算が desired より小さくても desired は保持し、非 desired を全部退避する")
    func budgetBelowDesiredKeepsDesired() {
        let desired = mesh("584177").neighborhood()
        let extra = [mesh("503324")]
        let plan = CachePlanner.plan(
            current: mesh("584177"), registered: [], cached: desired + extra, budgetCount: 4)
        #expect(plan.toEvict == extra)
        #expect(Set(plan.keep) == Set(desired))
    }

    @Test("一部だけキャッシュ済みなら不足分だけ DL する")
    func fetchesOnlyMissing() {
        let desired = mesh("584177").neighborhood()
        let have = Array(desired.prefix(4))
        let plan = CachePlanner.plan(
            current: mesh("584177"), registered: [], cached: have, budgetCount: 32)
        #expect(Set(plan.toFetch) == Set(desired).subtracting(have))
        #expect(Set(plan.keep) == Set(have))
        #expect(plan.toEvict.isEmpty)
    }
}
