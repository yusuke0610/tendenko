package atomfeed

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// fakeJMA は ATOM フィードと電文本体を提供する偽の気象庁。
// 実フィードへは開発環境から到達できない (ADR-0008)。
type fakeJMA struct {
	*httptest.Server
	mu         sync.Mutex
	feedHits   int
	fetched    []string
	etag       string
	entryFiles []string
	// dataStatus が 0 以外なら電文本体の取得をそのステータスで失敗させる。
	dataStatus int
	// brokenFeed を立てるとフィードとして解釈できない本文を返す。
	brokenFeed bool
}

func (f *fakeJMA) set(fn func(*fakeJMA)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(f)
}

func newFakeJMA(t *testing.T, entryFiles ...string) *fakeJMA {
	t.Helper()
	f := &fakeJMA{entryFiles: entryFiles}
	mux := http.NewServeMux()

	mux.HandleFunc("/feed", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.feedHits++
		etag := f.etag
		files := f.entryFiles
		broken := f.brokenFeed
		f.mu.Unlock()

		if etag != "" {
			if r.Header.Get("If-None-Match") == etag {
				w.WriteHeader(http.StatusNotModified)
				return
			}
			w.Header().Set("ETag", etag)
		}
		if broken {
			_, _ = fmt.Fprint(w, `<feed><entry>`)
			return
		}
		_, _ = fmt.Fprint(w, `<?xml version="1.0" encoding="UTF-8"?>`+"\n")
		_, _ = fmt.Fprint(w, `<feed xmlns="http://www.w3.org/2005/Atom">`)
		for i, name := range files {
			_, _ = fmt.Fprintf(w, `<entry><id>urn:uuid:%d</id><updated>2026-09-08T21:34:00Z</updated>`+
				`<link type="application/xml" href="%s/data/%s"/></entry>`, i, f.URL, name)
		}
		_, _ = fmt.Fprint(w, `</feed>`)
	})

	mux.HandleFunc("/data/", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.fetched = append(f.fetched, r.URL.Path)
		status := f.dataStatus
		f.mu.Unlock()
		if status != 0 {
			w.WriteHeader(status)
			return
		}
		_, _ = fmt.Fprintf(w, `<Report><Control><Title>%s</Title></Control></Report>`, r.URL.Path)
	})

	f.Server = httptest.NewServer(mux)
	t.Cleanup(f.Close)
	return f
}

func (f *fakeJMA) feedURL() string { return f.URL + "/feed" }

func (f *fakeJMA) counts() (feedHits int, fetched []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.feedHits, append([]string(nil), f.fetched...)
}

func collect(t *testing.T, c *Client) []Telegram {
	t.Helper()
	var got []Telegram
	if err := c.Poll(context.Background(), func(_ context.Context, tel Telegram) error {
		got = append(got, tel)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return got
}

func TestPollFetchesTargetTypesOnly(t *testing.T) {
	f := newFakeJMA(t,
		"20260908213400_0_VTSE41_010000.xml",
		"20260908213000_0_VXSE43_010000.xml",
		"20260908210000_0_VZSE40_010000.xml", // 対象外
	)
	c := New(Config{FeedURL: f.feedURL(), Types: []string{"VTSE41", "VXSE43"}})

	got := collect(t, c)
	if len(got) != 2 {
		t.Fatalf("電文 = %d 件、want 2", len(got))
	}
	if got[0].Type != "VTSE41" || got[1].Type != "VXSE43" {
		t.Errorf("types = %q, %q", got[0].Type, got[1].Type)
	}
	// 対象外の電文は本体をダウンロードすらしない
	_, fetched := f.counts()
	if len(fetched) != 2 {
		t.Errorf("ダウンロード = %v、want 2 件", fetched)
	}
}

// 60 秒間隔で叩き続けるため、同じ電文を毎回落とすと気象庁側にも自分にも無駄。
func TestPollSkipsAlreadyFetched(t *testing.T) {
	f := newFakeJMA(t, "20260908213400_0_VTSE41_010000.xml")
	c := New(Config{FeedURL: f.feedURL(), Types: []string{"VTSE41"}})

	if got := collect(t, c); len(got) != 1 {
		t.Fatalf("1 回目 = %d 件、want 1", len(got))
	}
	if got := collect(t, c); len(got) != 0 {
		t.Fatalf("2 回目 = %d 件、want 0", len(got))
	}
	if _, fetched := f.counts(); len(fetched) != 1 {
		t.Errorf("ダウンロード = %d 回、want 1", len(fetched))
	}
}

func TestPollHonorsETag(t *testing.T) {
	f := newFakeJMA(t, "20260908213400_0_VTSE41_010000.xml")
	f.mu.Lock()
	f.etag = `"v1"`
	f.mu.Unlock()

	c := New(Config{FeedURL: f.feedURL(), Types: []string{"VTSE41"}})
	collect(t, c)
	// 2 回目は 304 が返り、エントリは 0 件として扱われる
	if got := collect(t, c); len(got) != 0 {
		t.Fatalf("304 なのに %d 件返った", len(got))
	}
	if hits, _ := f.counts(); hits != 2 {
		t.Errorf("フィード取得 = %d 回、want 2", hits)
	}
}

// 取得が一時的に失敗した電文は、次回のポーリングで拾い直せなければならない。
// 二次経路は津波警報の縮退経路なので、1 通の欠落が案内フェーズの起動漏れになる。
func TestPollRetriesAfterFetchFailure(t *testing.T) {
	f := newFakeJMA(t, "20260908213400_0_VTSE41_010000.xml")
	f.set(func(f *fakeJMA) { f.dataStatus = http.StatusServiceUnavailable })
	c := New(Config{FeedURL: f.feedURL(), Types: []string{"VTSE41"}})

	if got := collect(t, c); len(got) != 0 {
		t.Fatalf("取得失敗なのに %d 件届いた", len(got))
	}
	f.set(func(f *fakeJMA) { f.dataStatus = 0 })
	if got := collect(t, c); len(got) != 1 {
		t.Errorf("再試行されなかった: %d 件", len(got))
	}
}

// 配信に失敗した電文も同様に拾い直せなければならない。
func TestPollRetriesAfterHandlerFailure(t *testing.T) {
	f := newFakeJMA(t, "20260908213400_0_VTSE41_010000.xml")
	c := New(Config{FeedURL: f.feedURL(), Types: []string{"VTSE41"}})

	err := c.Poll(context.Background(), func(context.Context, Telegram) error {
		return errors.New("publish failed")
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := collect(t, c); len(got) != 1 {
		t.Errorf("再試行されなかった: %d 件", len(got))
	}
}

// 解析に失敗した応答の ETag を覚えると、以降ずっと 304 が返って
// 二次経路が無音のまま停止する。
func TestPollDoesNotStoreETagOnParseFailure(t *testing.T) {
	f := newFakeJMA(t, "20260908213400_0_VTSE41_010000.xml")
	f.set(func(f *fakeJMA) {
		f.etag = `"v1"`
		f.brokenFeed = true
	})
	c := New(Config{FeedURL: f.feedURL(), Types: []string{"VTSE41"}})

	if err := c.Poll(context.Background(), func(context.Context, Telegram) error { return nil }); err == nil {
		t.Fatal("壊れたフィードはエラーになるはず")
	}
	// 健全でないのに /healthz が healthy と報告しないこと
	if c.Live() {
		t.Error("解析に失敗したのに Live() が true")
	}

	f.set(func(f *fakeJMA) { f.brokenFeed = false })
	if got := collect(t, c); len(got) != 1 {
		t.Errorf("304 で無音停止した: %d 件", len(got))
	}
}

func TestPollFeedError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()

	c := New(Config{FeedURL: srv.URL})
	if err := c.Poll(context.Background(), func(context.Context, Telegram) error { return nil }); err == nil {
		t.Fatal("503 はエラーになるはず")
	}
}

func TestTypeFromHref(t *testing.T) {
	for _, tc := range []struct{ href, want string }{
		{"https://example.test/data/20260908213400_0_VTSE41_010000.xml", "VTSE41"},
		{"20260908213000_0_VXSE43_010000.xml", "VXSE43"},
		{"https://example.test/data/broken.xml", ""},
	} {
		if got := typeFromHref(tc.href); got != tc.want {
			t.Errorf("typeFromHref(%q) = %q, want %q", tc.href, got, tc.want)
		}
	}
}
