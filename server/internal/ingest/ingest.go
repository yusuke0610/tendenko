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

// Config は取り込みの設定。Deduper・Logger・AtomInterval は未設定なら既定値を使う。
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

// Supervisor は一次・二次経路を束ね、電文を解析・重複排除して配信する。
type Supervisor struct {
	cfg Config
	// backfill は WS 再接続時に ATOM の単発取得を予約する。容量 1 で、
	// 予約済みなら捨てる (接続が不安定なときに取得が積み上がらないように)。
	backfill chan struct{}
}

// New は経路の監督を作る。WS が nil なら二次経路だけで、Atom が nil なら
// 一次経路だけで動く。
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

// Telegram は dmdata.Handler の実装。WS には再送の仕組みが無いためエラーは返せない。
// 配信に失敗した電文は Handle が重複排除の記録を取り消すので、二次経路が拾い直す。
func (s *Supervisor) Telegram(ctx context.Context, t dmdata.Telegram) {
	_ = s.Handle(ctx, t.Type, t.Body, alert.SourceDMDATA)
}

// Connected は dmdata.Handler の実装。WS 接続が確立するたびに呼ばれ、
// 切断中に発表された電文を ATOM から拾い直す (ADR-0008)。
func (s *Supervisor) Connected(context.Context) {
	select {
	case s.backfill <- struct{}{}:
	default:
	}
}

// onAtom は atomfeed.Handler の実装。エラーを返すと atomfeed 側が取得済み記録を
// 取り消し、次回のポーリングで同じ電文を拾い直す。
func (s *Supervisor) onAtom(ctx context.Context, t atomfeed.Telegram) error {
	return s.Handle(ctx, t.Type, t.Body, alert.SourceJMAAtom)
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
//
// エラーを返すのは、配信に失敗したときと、二次経路で解析に失敗したとき。呼び出し元
// (atomfeed) はこれを見て取得済み記録を取り消し、次回のポーリングで拾い直す。
// 対象外・訓練/試験の電文は再試行しても結果が変わらないため、エラーにはしない。
func (s *Supervisor) Handle(ctx context.Context, telegramType string, body []byte, src alert.Source) error {
	tel, err := jmaxml.Parse(telegramType, body)
	switch {
	case errors.Is(err, jmaxml.ErrUnsupportedType):
		// 対象外電文は購読の常態。黙って捨てる
		return nil
	case errors.Is(err, jmaxml.ErrNotOperational):
		s.cfg.Logger.Info("ingest: 訓練・試験電文を破棄した", "type", telegramType, "source", src, "reason", err)
		return nil
	case err != nil:
		s.cfg.Logger.Error("ingest: 電文を解析できない", "type", telegramType, "source", src, "error", err)
		// 二次経路は同じエントリを取り直せる。切れたダウンロードなどで一時的に壊れた
		// XML を握り潰すと、取得済み記録の TTL が切れるまで拾い直せない。恒久的に
		// 壊れた電文をフィードにある間だけ取り直す方が、警報を 1 通落とすより安い。
		// 一次経路 (WS) には再送が無いため、エラーを返しても意味がない。
		if src == alert.SourceJMAAtom {
			return err
		}
		return nil
	}

	key := tel.DedupKey()
	if s.cfg.Deduper.Seen(key) {
		return nil
	}

	msg := alert.FromTelegram(tel, src, s.cfg.now())
	if err := s.cfg.Publisher.Publish(ctx, msg); err != nil {
		// 記録を取り消して、もう一方の経路で同じ電文を拾い直せるようにする。
		// 二重配信より未配信の方がはるかに高くつく。
		s.cfg.Deduper.Forget(key)
		s.cfg.Logger.Error("ingest: 配信に失敗した", "kind", msg.Kind, "eventId", msg.EventID, "error", err)
		return err
	}
	s.cfg.Logger.Info("ingest: 配信した",
		"kind", msg.Kind, "type", msg.TelegramType, "eventId", msg.EventID, "source", src)
	return nil
}
