package dmdata

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeServer は socket.start と WebSocket の両方を提供する偽 DMDATA。
// 実 DMDATA へは開発環境から到達できない (ADR-0008) ため、購読経路の検証は
// これが唯一の手段になる。
type fakeServer struct {
	*httptest.Server
	// frames は接続確立後にサーバーから送るフレーム。
	frames []string
	// startCalls は socket.start が呼ばれた回数 (再接続の検証用)。
	startCalls int
	// closeAfterFrames を立てると、フレームを送り終えた時点でサーバー側から切断する。
	closeAfterFrames bool
	// received はクライアントから届いたフレーム (pong の検証用)。
	received chan string
	mu       sync.Mutex
}

func (f *fakeServer) setCloseAfterFrames() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closeAfterFrames = true
}

func newFakeServer(t *testing.T, frames ...string) *fakeServer {
	t.Helper()
	f := &fakeServer{frames: frames, received: make(chan string, 8)}
	mux := http.NewServeMux()

	mux.HandleFunc("/socket", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("key") == "" {
			http.Error(w, "no key", http.StatusUnauthorized)
			return
		}
		f.mu.Lock()
		f.startCalls++
		f.mu.Unlock()
		wsURL := "ws" + strings.TrimPrefix(f.URL, "http") + "/ws"
		_ = json.NewEncoder(w).Encode(map[string]any{"websocket": map[string]string{"url": wsURL}})
	})

	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		ctx := r.Context()
		for _, frame := range f.frames {
			if err := conn.Write(ctx, websocket.MessageText, []byte(frame)); err != nil {
				return
			}
		}
		f.mu.Lock()
		closeNow := f.closeAfterFrames
		f.mu.Unlock()
		if closeNow {
			return
		}
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			select {
			case f.received <- string(data):
			default:
			}
		}
	})

	f.Server = httptest.NewServer(mux)
	t.Cleanup(f.Close)
	return f
}

type recorder struct {
	mu         sync.Mutex
	telegrams  []Telegram
	connects   int
	connected  chan struct{}
	telegramCh chan Telegram
}

func newRecorder() *recorder {
	return &recorder{connected: make(chan struct{}, 8), telegramCh: make(chan Telegram, 8)}
}

func (r *recorder) Telegram(_ context.Context, t Telegram) {
	r.mu.Lock()
	r.telegrams = append(r.telegrams, t)
	r.mu.Unlock()
	select {
	case r.telegramCh <- t:
	default:
	}
}

func (r *recorder) Connected(context.Context) {
	r.mu.Lock()
	r.connects++
	r.mu.Unlock()
	select {
	case r.connected <- struct{}{}:
	default:
	}
}

func gzipBase64(t *testing.T, s string) string {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write([]byte(s)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

func testClient(t *testing.T, f *fakeServer) *Client {
	t.Helper()
	return New(Config{
		APIKey:     "test-key",
		AppName:    "tendenko-test",
		BaseURL:    f.URL,
		MinBackoff: time.Millisecond,
		MaxBackoff: 2 * time.Millisecond,
	})
}

func TestReceivesGzippedTelegram(t *testing.T) {
	const xml = `<Report><Control><Title>津波警報・注意報・予報</Title></Control></Report>`
	data, err := json.Marshal(map[string]any{
		"type":        "data",
		"head":        map[string]string{"type": "VTSE41"},
		"format":      "xml",
		"compression": "gzip",
		"encoding":    "base64",
		"body":        gzipBase64(t, xml),
	})
	if err != nil {
		t.Fatal(err)
	}
	f := newFakeServer(t, string(data))

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	rec := newRecorder()
	c := testClient(t, f)
	go func() { _ = c.Run(ctx, rec) }()

	select {
	case tel := <-rec.telegramCh:
		if tel.Type != "VTSE41" {
			t.Errorf("Type = %q, want VTSE41", tel.Type)
		}
		if string(tel.Body) != xml {
			t.Errorf("Body = %q, want %q", tel.Body, xml)
		}
	case <-ctx.Done():
		t.Fatal("電文が届かなかった")
	}
}

func TestRepliesToPing(t *testing.T) {
	f := newFakeServer(t, `{"type":"ping","pingId":"zmiL"}`)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c := testClient(t, f)
	go func() { _ = c.Run(ctx, newRecorder()) }()

	select {
	case got := <-f.received:
		var pong struct {
			Type   string `json:"type"`
			PingID string `json:"pingId"`
		}
		if err := json.Unmarshal([]byte(got), &pong); err != nil {
			t.Fatal(err)
		}
		// pong を返さないと DMDATA 側から切断される
		if pong.Type != "pong" || pong.PingID != "zmiL" {
			t.Errorf("pong = %+v", pong)
		}
	case <-ctx.Done():
		t.Fatal("pong が返らなかった")
	}
}

// Cloud Run はインスタンスを予告なく入れ替えるため、切断は常態として扱う (ADR-0001)。
// 再接続のたびに Connected が呼ばれ、バックフィルの起点になること。
func TestReconnectsAndSignalsBackfill(t *testing.T) {
	// フレームを送り終えたらサーバー側から閉じるので、切断→再接続が繰り返される
	f := newFakeServer(t)
	f.setCloseAfterFrames()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	rec := newRecorder()
	c := testClient(t, f)
	go func() { _ = c.Run(ctx, rec) }()

	for i := range 2 {
		select {
		case <-rec.connected:
		case <-ctx.Done():
			t.Fatalf("%d 回目の接続が来なかった", i+1)
		}
	}
	f.mu.Lock()
	calls := f.startCalls
	f.mu.Unlock()
	if calls < 2 {
		t.Errorf("socket.start = %d 回、want >= 2", calls)
	}
}

func TestSocketStartRequestShape(t *testing.T) {
	var got struct {
		Classifications []string `json:"classifications"`
		Types           []string `json:"types"`
		AppName         string   `json:"appName"`
	}
	done := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		close(done)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	c := New(Config{
		APIKey:          "k",
		AppName:         "tendenko",
		Classifications: []string{"telegram.earthquake"},
		Types:           []string{"VXSE43", "VTSE41"},
		BaseURL:         srv.URL,
	})
	if _, err := c.socketStart(context.Background()); err == nil {
		t.Fatal("500 はエラーになるはず")
	}
	<-done
	if len(got.Types) != 2 || got.Types[0] != "VXSE43" || got.AppName != "tendenko" {
		t.Errorf("request = %+v", got)
	}
	if len(got.Classifications) != 1 || got.Classifications[0] != "telegram.earthquake" {
		t.Errorf("classifications = %v", got.Classifications)
	}
}

// net/http は失敗を *url.Error で包み、そこに ?key= 付きの URL がそのまま入る。
// 素通しすると再接続ログに API キーが残る (CWE-532)。
func TestSocketStartErrorHidesAPIKey(t *testing.T) {
	const secret = "super-secret-key"
	// 接続できないアドレスにして HTTPClient.Do を失敗させる
	c := New(Config{APIKey: secret, BaseURL: "http://127.0.0.1:1"})

	_, err := c.socketStart(context.Background())
	if err == nil {
		t.Fatal("接続失敗はエラーになるはず")
	}
	if strings.Contains(err.Error(), secret) {
		t.Errorf("エラーに API キーが含まれる: %v", err)
	}
	// 原因そのもの (接続拒否など) は残っていること
	if !strings.Contains(err.Error(), "Post") {
		t.Errorf("原因が失われている: %v", err)
	}
}

func TestRedactURLKeepsCause(t *testing.T) {
	cause := errors.New("connection refused")
	err := redactURL(&url.Error{Op: "Get", URL: "https://api.example.test/socket?key=secret", Err: cause})
	if strings.Contains(err.Error(), "secret") {
		t.Errorf("URL が残っている: %v", err)
	}
	if !errors.Is(err, cause) {
		t.Errorf("原因が辿れない: %v", err)
	}
	// url.Error 以外はそのまま通す
	if got := redactURL(cause); got != cause {
		t.Errorf("redactURL(%v) = %v", cause, got)
	}
}

func TestSocketStartRequiresAPIKey(t *testing.T) {
	c := New(Config{BaseURL: "http://example.invalid"})
	if _, err := c.socketStart(context.Background()); err == nil {
		t.Fatal("API キーなしはエラーになるはず")
	}
}

func TestDecodeBody(t *testing.T) {
	for _, tc := range []struct {
		name string
		msg  envelope
		want string
	}{
		{"無圧縮 utf-8", envelope{Body: "<Report/>", Encoding: "utf-8"}, "<Report/>"},
		{"base64 のみ", envelope{Body: base64.StdEncoding.EncodeToString([]byte("<Report/>")), Encoding: "base64"}, "<Report/>"},
		{"gzip + base64", envelope{Body: gzipBase64(t, "<Report/>"), Encoding: "base64", Compression: "gzip"}, "<Report/>"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := decodeBody(tc.msg)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestDecodeBodyRejectsUnknownCompression(t *testing.T) {
	if _, err := decodeBody(envelope{Body: "x", Compression: "brotli"}); err == nil {
		t.Fatal("未知の圧縮形式はエラーになるはず")
	}
}
