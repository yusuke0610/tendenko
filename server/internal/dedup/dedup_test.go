package dedup

import (
	"sync"
	"testing"
	"time"
)

func TestMemorySeen(t *testing.T) {
	now := time.Date(2026, 9, 8, 21, 34, 0, 0, time.UTC)
	d := NewMemory(10*time.Minute, func() time.Time { return now })

	if d.Seen("a") {
		t.Error("初回は false のはず")
	}
	if !d.Seen("a") {
		t.Error("2 回目は true のはず")
	}
	if d.Seen("b") {
		t.Error("別キーは false のはず")
	}
}

// TTL を過ぎたキーは掃かれる。掃かないと発災時のバーストでメモリが際限なく太る。
func TestMemoryExpires(t *testing.T) {
	now := time.Date(2026, 9, 8, 21, 34, 0, 0, time.UTC)
	d := NewMemory(10*time.Minute, func() time.Time { return now })

	d.Seen("a")
	now = now.Add(11 * time.Minute)
	if d.Seen("a") {
		t.Error("TTL 経過後は false のはず")
	}
	if len(d.seen) != 1 {
		t.Errorf("期限切れが掃かれていない: %d 件", len(d.seen))
	}
}

// 一次経路と二次経路は別 goroutine から同時に流れ込む。
func TestMemoryConcurrent(t *testing.T) {
	d := NewMemory(time.Minute, nil)

	const n = 50
	var wg sync.WaitGroup
	firsts := make([]bool, n)
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			firsts[i] = !d.Seen("same-key")
		}()
	}
	wg.Wait()

	count := 0
	for _, first := range firsts {
		if first {
			count++
		}
	}
	if count != 1 {
		t.Errorf("初回判定が %d 件、want 1", count)
	}
}
