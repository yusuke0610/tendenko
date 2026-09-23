// subscriber は DMDATA.jp の WebSocket を常時購読し、EEW・津波電文を受信・解析して
// fanout へ渡す (requirements §3、ADR-0001、ADR-0008)。
//
// 設定はすべて環境変数から読み、Cloud Run 固有の API を使わない。ADR-0001 の
// 「コスト最適化が必要になったら subscriber のみ VM に戻す選択肢を残す」を
// 成立させるため、この main は実行基盤に依存しない。
//
// | 環境変数 | 既定 | 用途 |
// |---|---|---|
// | PORT | 8080 | ヘルスチェックの待ち受けポート |
// | DMDATA_API_KEY | (なし) | 未設定なら一次経路を無効化し ATOM だけで動く |
// | DMDATA_CLASSIFICATIONS | telegram.earthquake | socket.start の classifications |
// | DMDATA_BASE_URL | https://api.dmdata.jp/v2 | DMDATA API のベース URL (https のみ) |
// | ATOM_FEED_URL | 気象庁 eqvol.xml | 二次経路のフィード |
// | ATOM_INTERVAL | 60s | 二次経路のポーリング間隔 |
// | PUBSUB_PROJECT_ID | (なし) | 未設定なら標準出力へ書く |
// | PUBSUB_TOPIC | tendenko-alerts | 送出先トピック |
// | HEALTH_MAX_SILENCE | 5m | この時間受信が無ければ unhealthy |
// | DEDUP_TTL | 6h | 電文の重複排除を保持する時間 |
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/yusuke0610/tendenko/server/internal/atomfeed"
	"github.com/yusuke0610/tendenko/server/internal/dedup"
	"github.com/yusuke0610/tendenko/server/internal/dmdata"
	"github.com/yusuke0610/tendenko/server/internal/health"
	"github.com/yusuke0610/tendenko/server/internal/ingest"
	"github.com/yusuke0610/tendenko/server/internal/publisher"
)

// telegramTypes は購読対象の電文種別 (requirements §3.2)。
var telegramTypes = []string{"VXSE43", "VXSE45", "VTSE41", "VTSE51"}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, logger); err != nil && !errors.Is(err, context.Canceled) {
		logger.Error("subscriber: 異常終了", "error", err)
		os.Exit(1)
	}
	logger.Info("subscriber: 終了した")
}

func run(ctx context.Context, logger *slog.Logger) error {
	pub, err := newPublisher(ctx, logger)
	if err != nil {
		return err
	}
	defer func() {
		if err := pub.Close(); err != nil {
			logger.Warn("subscriber: publisher を閉じられない", "error", err)
		}
	}()

	var probes []health.Probe

	var ws *dmdata.Client
	if key := os.Getenv("DMDATA_API_KEY"); key != "" {
		ws = dmdata.New(dmdata.Config{
			APIKey:          key,
			AppName:         "tendenko",
			Classifications: splitEnv("DMDATA_CLASSIFICATIONS", "telegram.earthquake"),
			Types:           telegramTypes,
			BaseURL:         os.Getenv("DMDATA_BASE_URL"),
			Logger:          logger,
		})
		probes = append(probes, health.Probe{
			Name: "dmdata", Live: ws.Connected, LastActivity: ws.LastActivity,
		})
	} else {
		// 未契約でもプロセスは立ち上がる。ただし一次経路が無いのは縮退状態である
		logger.Warn("subscriber: DMDATA_API_KEY が未設定。一次経路なしで起動する")
	}

	atom := atomfeed.New(atomfeed.Config{
		FeedURL: os.Getenv("ATOM_FEED_URL"),
		Types:   telegramTypes,
		Logger:  logger,
	})
	probes = append(probes, health.Probe{
		Name: "jma_atom", Live: atom.Live, LastActivity: atom.LastSuccess,
	})

	sup := ingest.New(ingest.Config{
		Publisher:    pub,
		Deduper:      dedup.NewMemory(envDuration("DEDUP_TTL", 6*time.Hour), nil),
		Logger:       logger,
		WS:           ws,
		Atom:         atom,
		AtomInterval: envDuration("ATOM_INTERVAL", time.Minute),
	})

	checker := health.New(envDuration("HEALTH_MAX_SILENCE", 5*time.Minute), probes...)
	srv := healthServer(checker)

	// 待ち受けに失敗したまま購読を続けると、監視不能な subscriber が警報を配信し続ける。
	// ヘルスチェックが立たないことは起動失敗として扱い、プロセスごと落とす。
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	listenErr := make(chan error, 1)
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			listenErr <- err
			cancel()
		}
		close(listenErr)
	}()
	logger.Info("subscriber: 起動した", "addr", srv.Addr, "dmdata", ws != nil)
	runErr := sup.Run(ctx)

	// listenErr を待つ前に待ち受けを畳む。ListenAndServe は Shutdown されるまで
	// 戻らないため、順序を逆にすると SIGTERM で終われなくなる。
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	shutdownErr := srv.Shutdown(shutdownCtx)
	shutdownCancel()

	if err := <-listenErr; err != nil {
		return fmt.Errorf("ヘルスチェックの待ち受けに失敗した: %w", err)
	}
	if shutdownErr != nil {
		return fmt.Errorf("ヘルスチェックを停止できない: %w", shutdownErr)
	}
	return runErr
}

func healthServer(checker *health.Checker) *http.Server {
	mux := http.NewServeMux()
	mux.Handle("/healthz", checker)
	return &http.Server{
		Addr:              ":" + envString("PORT", "8080"),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
}

func newPublisher(ctx context.Context, logger *slog.Logger) (publisher.Publisher, error) {
	project := os.Getenv("PUBSUB_PROJECT_ID")
	if project == "" {
		logger.Warn("subscriber: PUBSUB_PROJECT_ID が未設定。標準出力へ書く")
		return publisher.NewStdout(os.Stdout), nil
	}
	return publisher.NewPubSub(ctx, project, envString("PUBSUB_TOPIC", "tendenko-alerts"))
}

func envString(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	// ゼロ以下も既定値に戻す。DEDUP_TTL が 0 なら dedup.Memory は記録を毎回期限切れと
	// して掃くため同じ電文を両経路から二重配信し、HEALTH_MAX_SILENCE が 0 なら
	// 受信していても healthy にならない。設定ミスが黙って通る方が危ない。
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		slog.Warn("subscriber: 期間が不正。既定値を使う", "key", key, "value", v, "default", fallback)
		return fallback
	}
	return d
}

func splitEnv(key, fallback string) []string {
	return strings.Split(envString(key, fallback), ",")
}
