// Package dedup は電文の重複排除を行う (ADR-0008)。
//
// 同じ電文が一次経路 (DMDATA WS) と二次経路 (気象庁 ATOM) の両方から届くのは
// 異常ではなく設計上の常態である。再接続直後のバックフィルは意図的に二重取得する。
// したがって重複排除は例外処理ではなく主経路の一部。
package dedup

import (
	"sync"
	"time"
)

// Deduper は電文を一度だけ通す。
type Deduper interface {
	// Seen はキーを記録し、記録済みだった場合に true を返す。
	Seen(key string) bool
	// Forget は記録を取り消す。配信に失敗した電文をもう一方の経路で拾い直せるようにする。
	// 警報を二重に送るコストより、送れないコストの方がはるかに大きい。
	Forget(key string)
}

// Memory は単一プロセス内の TTL 付き重複排除。
//
// Stage 1 (単一インスタンス、min-instances=1) 専用である。ADR-0001 Stage 2 の
// multi-region active-active に進んだ時点でこれは機能しなくなるため、
// 共有ストア実装 (Firestore トランザクション等) への差し替えが必須になる。
type Memory struct {
	ttl  time.Duration
	now  func() time.Time
	mu   sync.Mutex
	seen map[string]time.Time
}

// NewMemory は TTL 付きの重複排除を作る。now は nil なら time.Now を使う。
func NewMemory(ttl time.Duration, now func() time.Time) *Memory {
	if now == nil {
		now = time.Now
	}
	return &Memory{ttl: ttl, now: now, seen: make(map[string]time.Time)}
}

// Seen はキーを記録し、記録済みだった場合に true を返す。呼ぶたびに期限切れを掃く。
func (m *Memory) Seen(key string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	t := m.now()
	// 発災時のバーストで際限なく太らないよう、記録のたびに期限切れを掃く
	for k, at := range m.seen {
		if t.Sub(at) >= m.ttl {
			delete(m.seen, k)
		}
	}
	if at, ok := m.seen[key]; ok && t.Sub(at) < m.ttl {
		return true
	}
	m.seen[key] = t
	return false
}

// Forget は記録を取り消し、同じ電文を別経路で拾い直せるようにする。
func (m *Memory) Forget(key string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.seen, key)
}
