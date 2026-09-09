package ingest

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/yusuke0610/tendenko/server/internal/alert"
	"github.com/yusuke0610/tendenko/server/internal/dedup"
	"github.com/yusuke0610/tendenko/server/internal/dmdata"
)

const alertXML = `<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://xml.kishou.go.jp/jmaxml1/">
  <Control><Title>津波警報・注意報・予報</Title><Status>通常</Status></Control>
  <Head xmlns="http://xml.kishou.go.jp/jmaxml1/informationBasis1/">
    <ReportDateTime>2026-09-08T21:34:00+09:00</ReportDateTime>
    <EventID>20260908213000</EventID><InfoType>発表</InfoType><Serial>1</Serial>
    <InfoKind>津波警報・注意報・予報</InfoKind>
  </Head>
  <Body xmlns="http://xml.kishou.go.jp/jmaxml1/body/seismology1/">
    <Tsunami><Forecast><Item>
      <Area><Name>岩手県</Name><Code>212</Code></Area>
      <Category><Kind><Name>大津波警報</Name><Code>51</Code></Kind></Category>
    </Item></Forecast></Tsunami>
  </Body>
</Report>`

const drillXML = `<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://xml.kishou.go.jp/jmaxml1/">
  <Control><Title>津波警報・注意報・予報</Title><Status>訓練</Status></Control>
  <Head xmlns="http://xml.kishou.go.jp/jmaxml1/informationBasis1/">
    <EventID>20260908110000</EventID><InfoType>発表</InfoType><Serial>1</Serial>
  </Head>
  <Body xmlns="http://xml.kishou.go.jp/jmaxml1/body/seismology1/">
    <Tsunami><Forecast><Item>
      <Area><Name>岩手県</Name><Code>212</Code></Area>
      <Category><Kind><Name>大津波警報</Name><Code>51</Code></Kind></Category>
    </Item></Forecast></Tsunami>
  </Body>
</Report>`

type fakePublisher struct {
	mu   sync.Mutex
	msgs []alert.Message
	err  error
	ch   chan alert.Message
}

func newFakePublisher() *fakePublisher {
	return &fakePublisher{ch: make(chan alert.Message, 8)}
}

func (p *fakePublisher) Publish(_ context.Context, m alert.Message) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.err != nil {
		return p.err
	}
	p.msgs = append(p.msgs, m)
	select {
	case p.ch <- m:
	default:
	}
	return nil
}

func (p *fakePublisher) Close() error { return nil }

func (p *fakePublisher) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.msgs)
}

func (p *fakePublisher) setErr(err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.err = err
}

func newSupervisor(t *testing.T, pub *fakePublisher) *Supervisor {
	t.Helper()
	return New(Config{
		Publisher: pub,
		Deduper:   dedup.NewMemory(time.Hour, nil),
		Logger:    slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
}

func TestHandlePublishes(t *testing.T) {
	pub := newFakePublisher()
	s := newSupervisor(t, pub)

	_ = s.Handle(context.Background(), "VTSE41", []byte(alertXML), alert.SourceDMDATA)

	if pub.count() != 1 {
		t.Fatalf("配信 = %d 件、want 1", pub.count())
	}
	m := pub.msgs[0]
	if m.Kind != "tsunami_alert" || m.MaxCategory != "大津波警報" || m.Source != alert.SourceDMDATA {
		t.Errorf("message = %+v", m)
	}
}

// 同じ電文が一次経路と二次経路の両方から届くのは設計上の常態。
func TestHandleDedupsAcrossSources(t *testing.T) {
	pub := newFakePublisher()
	s := newSupervisor(t, pub)

	_ = s.Handle(context.Background(), "VTSE41", []byte(alertXML), alert.SourceDMDATA)
	_ = s.Handle(context.Background(), "VTSE41", []byte(alertXML), alert.SourceJMAAtom)

	if pub.count() != 1 {
		t.Errorf("配信 = %d 件、want 1", pub.count())
	}
}

// 訓練電文を実警報として流すのは最も避けるべき事故。
func TestHandleDropsDrill(t *testing.T) {
	pub := newFakePublisher()
	s := newSupervisor(t, pub)

	_ = s.Handle(context.Background(), "VTSE41", []byte(drillXML), alert.SourceDMDATA)

	if pub.count() != 0 {
		t.Errorf("訓練電文が配信された: %+v", pub.msgs)
	}
}

func TestHandleSkipsUnsupportedAndMalformed(t *testing.T) {
	pub := newFakePublisher()
	s := newSupervisor(t, pub)

	_ = s.Handle(context.Background(), "VZSE40", []byte(alertXML), alert.SourceDMDATA)
	_ = s.Handle(context.Background(), "VTSE41", []byte("<Report>"), alert.SourceDMDATA)

	if pub.count() != 0 {
		t.Errorf("配信 = %d 件、want 0", pub.count())
	}
}

// 配信に失敗した電文は記録を取り消し、もう一方の経路で拾い直せるようにする。
// 二重配信より未配信の方がはるかに高くつく。
func TestHandleRetriesAfterPublishFailure(t *testing.T) {
	pub := newFakePublisher()
	pub.setErr(errors.New("pubsub down"))
	s := newSupervisor(t, pub)

	// 配信失敗はエラーとして返す。atomfeed 側はこれを見て取得済み記録を取り消す
	if err := s.Handle(context.Background(), "VTSE41", []byte(alertXML), alert.SourceDMDATA); err == nil {
		t.Fatal("配信失敗がエラーとして返っていない")
	}
	if pub.count() != 0 {
		t.Fatal("失敗したのに記録されている")
	}

	pub.setErr(nil)
	if err := s.Handle(context.Background(), "VTSE41", []byte(alertXML), alert.SourceJMAAtom); err != nil {
		t.Fatal(err)
	}
	if pub.count() != 1 {
		t.Errorf("再試行が抑止された: 配信 = %d 件", pub.count())
	}
}

// 捨てるべき電文は再試行しても結果が変わらないので、エラーにはしない。
// ここをエラーにすると atomfeed が毎回同じ電文を取り直し続ける。
func TestHandleDoesNotErrorOnDiscardedTelegrams(t *testing.T) {
	pub := newFakePublisher()
	s := newSupervisor(t, pub)

	for _, tc := range []struct {
		name, telegramType string
		body               string
	}{
		{"対象外", "VZSE40", alertXML},
		{"訓練", "VTSE41", drillXML},
		{"解析不能", "VTSE41", "<Report>"},
	} {
		if err := s.Handle(context.Background(), tc.telegramType, []byte(tc.body), alert.SourceJMAAtom); err != nil {
			t.Errorf("%s: err = %v, want nil", tc.name, err)
		}
	}
}

// WS 受信から配信までの通し。実 DMDATA へは到達できない (ADR-0008) ため、
// 購読経路の検証はこれが最も実物に近い。
func TestEndToEndFromWebSocket(t *testing.T) {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write([]byte(alertXML)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	frame, err := json.Marshal(map[string]any{
		"type":        "data",
		"head":        map[string]string{"type": "VTSE41"},
		"format":      "xml",
		"compression": "gzip",
		"encoding":    "base64",
		"body":        base64.StdEncoding.EncodeToString(buf.Bytes()),
	})
	if err != nil {
		t.Fatal(err)
	}

	var srv *httptest.Server
	mux := http.NewServeMux()
	mux.HandleFunc("/socket", func(w http.ResponseWriter, _ *http.Request) {
		wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
		_ = json.NewEncoder(w).Encode(map[string]any{"websocket": map[string]string{"url": wsURL}})
	})
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		_ = conn.Write(r.Context(), websocket.MessageText, frame)
		<-r.Context().Done()
	})
	srv = httptest.NewServer(mux)
	defer srv.Close()

	pub := newFakePublisher()
	s := New(Config{
		Publisher: pub,
		Deduper:   dedup.NewMemory(time.Hour, nil),
		Logger:    slog.New(slog.NewTextHandler(io.Discard, nil)),
		WS: dmdata.New(dmdata.Config{
			APIKey:     "test-key",
			BaseURL:    srv.URL,
			MinBackoff: time.Millisecond,
			MaxBackoff: 2 * time.Millisecond,
		}),
	})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go func() { _ = s.Run(ctx) }()

	select {
	case m := <-pub.ch:
		if m.Kind != "tsunami_alert" || m.TelegramType != "VTSE41" || m.EventID != "20260908213000" {
			t.Errorf("message = %+v", m)
		}
		if m.Source != alert.SourceDMDATA {
			t.Errorf("Source = %q", m.Source)
		}
	case <-ctx.Done():
		t.Fatal("WS から配信まで到達しなかった")
	}
}
