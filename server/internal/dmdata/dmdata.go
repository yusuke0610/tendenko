// Package dmdata は DMDATA.jp API v2 の WebSocket を購読する一次経路 (requirements §3.3)。
//
// Cloud Run のインスタンスは予告なく入れ替わるため、切断は異常ではなく常態として扱う
// (ADR-0001)。Run は ctx が切れるまで指数バックオフで再接続し続け、接続が確立するたびに
// Handler.Connected を呼ぶ。呼ばれた側は ATOM バックフィルを走らせて切断中の穴を埋める
// (ADR-0008)。
//
// 注意: 本パッケージのプロトコル理解は非公式クライアントのソースに依拠した二次情報であり、
// DMDATA 公式リファレンスと未照合である (開発環境から dmdata.jp へ到達できない)。
// 照合が済むまで本番投入しない。詳細は ADR-0008「一次情報の確認」を参照。
package dmdata

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// DefaultBaseURL は DMDATA API v2 のベース URL。
const DefaultBaseURL = "https://api.dmdata.jp/v2"

// readLimit は 1 フレームの上限。coder/websocket の既定は 32KiB で、
// 津波電文 (地域数が多い) はこれを超えうるため明示的に引き上げる。
const readLimit = 8 << 20

// Telegram は受信した生電文。解析は jmaxml パッケージが行う。
type Telegram struct {
	// Type は電文種別コード (VTSE41 等)。気象庁 XML 本文には含まれず、
	// DMDATA の head.type が唯一の出どころ。
	Type string
	Body []byte
}

// Handler は購読中のイベントを受け取る。
type Handler interface {
	// Telegram は電文を 1 通受け取る。重複排除は呼び出し先の責務。
	Telegram(ctx context.Context, t Telegram)
	// Connected は WS 接続が確立するたびに呼ばれる (初回・再接続とも)。
	// 切断中の取りこぼしを埋めるバックフィルの起点。
	Connected(ctx context.Context)
}

// Config は一次経路の設定。ゼロ値のフィールドは New が既定値で埋める。
type Config struct {
	APIKey          string
	AppName         string
	Classifications []string
	Types           []string
	BaseURL         string
	HTTPClient      *http.Client
	Logger          *slog.Logger
	// MinBackoff / MaxBackoff は再接続間隔。ゼロなら既定値を使う。
	MinBackoff time.Duration
	MaxBackoff time.Duration
	now        func() time.Time
}

// Client は DMDATA.jp の WebSocket 購読クライアント。複数 goroutine から使える。
type Client struct {
	cfg Config

	mu           sync.Mutex
	connected    bool
	lastActivity time.Time
}

// New は購読クライアントを作る。BaseURL・HTTPClient・Logger・バックオフ間隔は
// 未設定なら既定値を使う。
func New(cfg Config) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = DefaultBaseURL
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 30 * time.Second}
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.MinBackoff <= 0 {
		cfg.MinBackoff = time.Second
	}
	if cfg.MaxBackoff <= 0 {
		cfg.MaxBackoff = 30 * time.Second
	}
	if cfg.now == nil {
		cfg.now = time.Now
	}
	return &Client{cfg: cfg}
}

// Connected は WS 接続が確立しているかを返す (ヘルスチェック用)。
func (c *Client) Connected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

// LastActivity は最後に WS 上で何かを受信した時刻を返す。ADR-0001 が求める
// 「プロセス生存ではなく、直近 N 分以内に keepalive を受信していること」の判定材料。
func (c *Client) LastActivity() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastActivity
}

func (c *Client) touch() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastActivity = c.cfg.now()
}

func (c *Client) setConnected(v bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.connected = v
	if v {
		c.lastActivity = c.cfg.now()
	}
}

// Run は ctx が切れるまで購読し続ける。個々の接続失敗はバックオフして再試行し、
// エラーを返さない。返るのは ctx がキャンセルされたときだけ。
func (c *Client) Run(ctx context.Context, h Handler) error {
	backoff := c.cfg.MinBackoff
	for {
		err := c.session(ctx, h)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		c.cfg.Logger.Warn("dmdata: 接続が切れた。再接続する", "error", err, "backoff", backoff)

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(jitter(backoff)):
		}
		if backoff *= 2; backoff > c.cfg.MaxBackoff {
			backoff = c.cfg.MaxBackoff
		}
	}
}

// jitter は full jitter。再接続が同時に殺到して DMDATA 側を叩かないようにする。
func jitter(d time.Duration) time.Duration {
	if d <= 0 {
		return 0
	}
	return time.Duration(rand.Int64N(int64(d))) + d/2
}

// session は 1 回の接続を張り、切れるまで読み続ける。
func (c *Client) session(ctx context.Context, h Handler) error {
	wsURL, err := c.socketStart(ctx)
	if err != nil {
		return fmt.Errorf("socket.start: %w", err)
	}

	// WS の URL にはチケットが載るため、エラーからも URL を落とす
	conn, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPClient: c.cfg.HTTPClient})
	if err != nil {
		return fmt.Errorf("dial: %w", redactURL(err))
	}
	defer conn.CloseNow()
	conn.SetReadLimit(readLimit)

	c.setConnected(true)
	defer c.setConnected(false)
	h.Connected(ctx)

	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return err
		}
		c.touch()
		if err := c.dispatch(ctx, conn, data, h); err != nil {
			return err
		}
	}
}

type envelope struct {
	Type   string `json:"type"`
	PingID string `json:"pingId"`
	Head   struct {
		Type string `json:"type"`
	} `json:"head"`
	Format      string `json:"format"`
	Compression string `json:"compression"`
	Encoding    string `json:"encoding"`
	Body        string `json:"body"`
	Error       string `json:"error"`
	Close       bool   `json:"close"`
}

func (c *Client) dispatch(ctx context.Context, conn *websocket.Conn, data []byte, h Handler) error {
	var msg envelope
	if err := json.Unmarshal(data, &msg); err != nil {
		// 1 通の解釈に失敗しても購読は止めない
		c.cfg.Logger.Warn("dmdata: メッセージを解釈できない", "error", err)
		return nil
	}

	switch msg.Type {
	case "ping":
		// pong を返さないと DMDATA 側から切断される
		pong, err := json.Marshal(map[string]string{"type": "pong", "pingId": msg.PingID})
		if err != nil {
			return err
		}
		writeCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		return conn.Write(writeCtx, websocket.MessageText, pong)

	case "data":
		body, err := decodeBody(msg)
		if err != nil {
			c.cfg.Logger.Warn("dmdata: 電文を復号できない", "type", msg.Head.Type, "error", err)
			return nil
		}
		h.Telegram(ctx, Telegram{Type: msg.Head.Type, Body: body})
		return nil

	case "error":
		// close 付きのエラーは再接続を促す。それ以外は継続する
		if msg.Close {
			return fmt.Errorf("dmdata: サーバーがエラーで切断した: %s", msg.Error)
		}
		c.cfg.Logger.Warn("dmdata: サーバーからエラー通知", "error", msg.Error)
		return nil

	default:
		// start・pong 等。接続が生きている証拠なので touch 済みでよい
		return nil
	}
}

// decodeBody は base64 デコードと gzip 展開を行う。
// compression が gzip のとき encoding は常に base64。
func decodeBody(msg envelope) ([]byte, error) {
	raw := []byte(msg.Body)
	if strings.EqualFold(msg.Encoding, "base64") {
		decoded, err := base64.StdEncoding.DecodeString(msg.Body)
		if err != nil {
			return nil, fmt.Errorf("base64: %w", err)
		}
		raw = decoded
	}

	switch strings.ToLower(msg.Compression) {
	case "", "none":
		return raw, nil
	case "gzip":
		zr, err := gzip.NewReader(bytes.NewReader(raw))
		if err != nil {
			return nil, fmt.Errorf("gzip: %w", err)
		}
		defer zr.Close()
		out, err := io.ReadAll(io.LimitReader(zr, readLimit))
		if err != nil {
			return nil, fmt.Errorf("gzip: %w", err)
		}
		return out, nil
	default:
		return nil, fmt.Errorf("未知の圧縮形式: %s", msg.Compression)
	}
}

// redactURL は URL を含みうるエラーから URL を落とす。
//
// net/http は失敗を *url.Error で包み、そこにリクエスト URL がそのまま入る。
// socket.start の URL には API キーが、WebSocket の URL にはチケットが載るため、
// 素通しすると Run の再接続ログに資格情報が残ってしまう (CWE-532)。
// 原因そのもの (接続拒否・タイムアウト等) は URL を含まないので残す。
func redactURL(err error) error {
	var uerr *url.Error
	if errors.As(err, &uerr) {
		return fmt.Errorf("%s: %w", uerr.Op, uerr.Err)
	}
	return err
}

// socketStart は WebSocket の接続先 URL を払い出す。
// API キーはクエリ ?key= で渡す (DMDATA API v2 の仕様)。
func (c *Client) socketStart(ctx context.Context) (string, error) {
	if c.cfg.APIKey == "" {
		return "", errors.New("dmdata: API キーが未設定")
	}
	reqBody, err := json.Marshal(map[string]any{
		"classifications": c.cfg.Classifications,
		"types":           c.cfg.Types,
		"appName":         c.cfg.AppName,
	})
	if err != nil {
		return "", err
	}

	endpoint := c.cfg.BaseURL + "/socket?key=" + c.cfg.APIKey
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(reqBody))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.cfg.HTTPClient.Do(req)
	if err != nil {
		return "", redactURL(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// API キーをログに出さないよう、本文は先頭のみに切る
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("status %d: %s", resp.StatusCode, bytes.TrimSpace(snippet))
	}

	var out struct {
		WebSocket struct {
			URL string `json:"url"`
		} `json:"websocket"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if out.WebSocket.URL == "" {
		return "", errors.New("dmdata: socket.start が URL を返さなかった")
	}
	return out.WebSocket.URL, nil
}
