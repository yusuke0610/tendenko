package atomfeed

import (
	"context"
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
		f.mu.Unlock()

		if etag != "" {
			if r.Header.Get("If-None-Match") == etag {
				w.WriteHeader(http.StatusNotModified)
				return
			}
			w.Header().Set("ETag", etag)
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
		f.mu.Unlock()
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
	if err := c.Poll(context.Background(), func(_ context.Context, tel Telegram) {
		got = append(got, tel)
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

func TestPollFeedError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()

	c := New(Config{FeedURL: srv.URL})
	if err := c.Poll(context.Background(), func(context.Context, Telegram) {}); err == nil {
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
