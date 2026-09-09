// Package ingest は一次・二次経路から届いた電文を解析・重複排除して配信する。
//
// 二次経路 (ATOM) は「DMDATA 障害時だけ動かす」のではなく常時ポーリングする。
// 切り替えロジックを持たないぶん単純で、かつフォールバック経路が日常的に
// 実行されるため「いざというとき動かない」状態になりにくい。二重に届く分は
// 重複排除が吸収する (ADR-0008)。
package ingest

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/yusuke0610/tendenko/server/internal/alert"
	"github.com/yusuke0610/tendenko/server/internal/atomfeed"
	"github.com/yusuke0610/tendenko/server/internal/dedup"
	"github.com/yusuke0610/tendenko/server/internal/dmdata"
	"github.com/yusuke0610/tendenko/server/internal/jmaxml"
	"github.com/yusuke0610/tendenko/server/internal/publisher"
)

type Config struct {
	Publisher publisher.Publisher
	Deduper   dedup.Deduper
	Logger    *slog.Logger
	// WS は一次経路。nil なら二次経路だけで動く (DMDATA 未契約時)。
	WS *dmdata.Client
	// Atom は二次経路。nil なら一次経路だけで動く。
	Atom         *atomfeed.Client
	AtomInterval time.Duration
	now          func() time.Time
}

type Supervisor struct {
	cfg Config
	// backfill は WS 再接続時に ATOM の単発取得を予約する。容量 1 で、
	// 予約済みなら捨てる (接続が不安定なときに取得が積み上がらないように)。
	backfill chan struct{}
}

func New(cfg Config) *Supervisor {
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.Deduper == nil {
		cfg.Deduper = dedup.NewMemory(6*time.Hour, nil)
	}
	if cfg.AtomInterval <= 0 {
		cfg.AtomInterval = time.Minute
	}
	if cfg.now == nil {
		cfg.now = time.Now
	}
	return &Supervisor{cfg: cfg, backfill: make(chan struct{}, 1)}
}

// Run は設定された経路をすべて起動し、ctx が切れるまで戻らない。
func (s *Supervisor) Run(ctx context.Context) error {
	var wg sync.WaitGroup
	start := func(fn func()) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			fn()
		}()
	}

	if s.cfg.WS != nil {
		start(func() { _ = s.cfg.WS.Run(ctx, s) })
	}
	if s.cfg.Atom != nil {
		start(func() { _ = s.cfg.Atom.Run(ctx, s.cfg.AtomInterval, s.onAtom) })
		start(func() { s.backfillLoop(ctx) })
	}

	<-ctx.Done()
	wg.Wait()
	return ctx.Err()
}

// Telegram は dmdata.Handler の実装。
func (s *Supervisor) Telegram(ctx context.Context, t dmdata.Telegram) {
	s.Handle(ctx, t.Type, t.Body, alert.SourceDMDATA)
}

// Connected は dmdata.Handler の実装。WS 接続が確立するたびに呼ばれ、
// 切断中に発表された電文を ATOM から拾い直す (ADR-0008)。
func (s *Supervisor) Connected(context.Context) {
	select {
	case s.backfill <- struct{}{}:
	default:
	}
}

func (s *Supervisor) onAtom(ctx context.Context, t atomfeed.Telegram) {
	s.Handle(ctx, t.Type, t.Body, alert.SourceJMAAtom)
}

func (s *Supervisor) backfillLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.backfill:
			if err := s.cfg.Atom.Poll(ctx, s.onAtom); err != nil && ctx.Err() == nil {
				s.cfg.Logger.Warn("ingest: バックフィルに失敗した", "error", err)
			}
		}
	}
}

// Handle は生電文 1 通を解析・重複排除して配信する。
func (s *Supervisor) Handle(ctx context.Context, telegramType string, body []byte, src alert.Source) {
	tel, err := jmaxml.Parse(telegramType, body)
	switch {
	case errors.Is(err, jmaxml.ErrUnsupportedType):
		// 対象外電文は購読の常態。黙って捨てる
		return
	case errors.Is(err, jmaxml.ErrNotOperational):
		s.cfg.Logger.Info("ingest: 訓練・試験電文を破棄した", "type", telegramType, "source", src)
		return
	case err != nil:
		s.cfg.Logger.Error("ingest: 電文を解析できない", "type", telegramType, "source", src, "error", err)
		return
	}

	key := tel.DedupKey()
	if s.cfg.Deduper.Seen(key) {
		return
	}

	msg := alert.FromTelegram(tel, src, s.cfg.now())
	if err := s.cfg.Publisher.Publish(ctx, msg); err != nil {
		// 記録を取り消して、もう一方の経路で同じ電文を拾い直せるようにする。
		// 二重配信より未配信の方がはるかに高くつく。
		s.cfg.Deduper.Forget(key)
		s.cfg.Logger.Error("ingest: 配信に失敗した", "kind", msg.Kind, "eventId", msg.EventID, "error", err)
		return
	}
	s.cfg.Logger.Info("ingest: 配信した",
		"kind", msg.Kind, "type", msg.TelegramType, "eventId", msg.EventID, "source", src)
}
