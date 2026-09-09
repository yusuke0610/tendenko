// Package atomfeed は気象庁防災情報 XML の ATOM フィードをポーリングする二次経路
// (requirements §3.3)。
//
// 役割は 2 つある。
//
//  1. DMDATA 障害時の縮退運用 (requirements §3.3)
//  2. WS 再接続直後のバックフィル (ADR-0008)
//
// 2 があるため、この経路は「障害時だけ動く、普段は死んでいるコード」にならない。
// 再接続のたびに叩かれるので、フォールバックの動作が日常的に検証される。
package atomfeed

import (
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"path"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/yusuke0610/tendenko/server/internal/dedup"
)

// DefaultFeedURL は地震・火山関連の電文が流れるフィード。
const DefaultFeedURL = "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml"

// maxTelegramBytes は 1 電文の読み取り上限。
const maxTelegramBytes = 8 << 20

// telegramTypePattern は電文ファイル名に埋まった電文種別コード (VTSE41 等) にあたる。
// 気象庁 XML の本文に種別コードは含まれないため、ここが二次経路での唯一の出どころ。
var telegramTypePattern = regexp.MustCompile(`^[A-Z]{4}[0-9]{2}$`)

type Telegram struct {
	Type string
	Body []byte
}

type Config struct {
	FeedURL    string
	HTTPClient *http.Client
	Logger     *slog.Logger
	// Types は取得対象の電文種別。空なら全件取得する。
	Types []string
	// Fetched は取得済みエントリの記録。同じ電文を毎回ダウンロードしないためのもので、
	// 配信の重複排除 (ingest 側) とは別の関心事。nil なら既定の in-memory を使う。
	Fetched dedup.Deduper
}

type Client struct {
	cfg   Config
	types map[string]bool

	mu          sync.Mutex
	etag        string
	lastSuccess time.Time
}

// LastSuccess は最後にフィード取得に成功した時刻 (ヘルスチェック用)。
// 304 も「経路が生きている」証拠なので成功として数える。
func (c *Client) LastSuccess() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastSuccess
}

// Live は二次経路が機能しているかを返す。
func (c *Client) Live() bool { return !c.LastSuccess().IsZero() }

func New(cfg Config) *Client {
	if cfg.FeedURL == "" {
		cfg.FeedURL = DefaultFeedURL
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 30 * time.Second}
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.Fetched == nil {
		cfg.Fetched = dedup.NewMemory(6*time.Hour, nil)
	}
	types := make(map[string]bool, len(cfg.Types))
	for _, t := range cfg.Types {
		types[t] = true
	}
	return &Client{cfg: cfg, types: types}
}

type link struct {
	Href string `xml:"href,attr"`
}

type entry struct {
	ID      string `xml:"id"`
	Updated string `xml:"updated"`
	Links   []link `xml:"link"`
}

type feed struct {
	Entries []entry `xml:"entry"`
}

// Run は interval ごとに Poll する。ctx が切れるまで戻らない。
// 個々のポーリング失敗はログに残して継続する (縮退経路が落ちても購読は止めない)。
func (c *Client) Run(ctx context.Context, interval time.Duration, h func(context.Context, Telegram)) error {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if err := c.Poll(ctx, h); err != nil && ctx.Err() == nil {
			c.cfg.Logger.Warn("atomfeed: ポーリングに失敗した", "error", err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

// Poll はフィードを 1 回取得し、未取得の対象電文をダウンロードして h に渡す。
func (c *Client) Poll(ctx context.Context, h func(context.Context, Telegram)) error {
	entries, err := c.fetchFeed(ctx)
	if err != nil {
		return err
	}
	for _, e := range entries {
		href := telegramHref(e.Links)
		if href == "" {
			continue
		}
		telegramType := typeFromHref(href)
		if len(c.types) > 0 && !c.types[telegramType] {
			continue
		}
		// 同じ電文を毎回ダウンロードしないための記録。updated を含めて訂正報も拾う
		if c.cfg.Fetched.Seen(e.ID + "|" + e.Updated) {
			continue
		}
		body, err := c.fetchTelegram(ctx, href)
		if err != nil {
			c.cfg.Logger.Warn("atomfeed: 電文を取得できない", "href", href, "error", err)
			continue
		}
		h(ctx, Telegram{Type: telegramType, Body: body})
	}
	return nil
}

func (c *Client) fetchFeed(ctx context.Context) ([]entry, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.cfg.FeedURL, nil)
	if err != nil {
		return nil, err
	}
	// 60 秒間隔で叩き続けるため、変化が無いときは気象庁側に本文を返させない
	c.mu.Lock()
	if c.etag != "" {
		req.Header.Set("If-None-Match", c.etag)
	}
	c.mu.Unlock()

	resp, err := c.cfg.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotModified {
		c.markSuccess("")
		return nil, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("atomfeed: status %d", resp.StatusCode)
	}
	c.markSuccess(resp.Header.Get("ETag"))

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxTelegramBytes))
	if err != nil {
		return nil, err
	}
	var f feed
	if err := xml.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("atomfeed: フィードを解釈できない: %w", err)
	}
	return f.Entries, nil
}

func (c *Client) markSuccess(etag string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastSuccess = time.Now()
	if etag != "" {
		c.etag = etag
	}
}

func (c *Client) fetchTelegram(ctx context.Context, href string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, href, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.cfg.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, maxTelegramBytes))
}

func telegramHref(links []link) string {
	for _, l := range links {
		if l.Href != "" {
			return l.Href
		}
	}
	return ""
}

// typeFromHref は電文ファイル名 (例 20260908213400_0_VTSE41_010000.xml) から
// 電文種別コードを取り出す。
func typeFromHref(href string) string {
	base := strings.TrimSuffix(path.Base(href), ".xml")
	for _, part := range strings.Split(base, "_") {
		if telegramTypePattern.MatchString(part) {
			return part
		}
	}
	return ""
}
