package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const emptyFeed = `<?xml version="1.0" encoding="UTF-8"?><feed xmlns="http://www.w3.org/2005/Atom"></feed>`

// setupEnv は二次経路だけで動く最小構成を環境変数で組む。実 DMDATA へは開発環境から
// 到達できない (ADR-0008) ため、起動と終了の検証はこの構成で行う。
func setupEnv(t *testing.T) {
	t.Helper()
	feed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		_, _ = io.WriteString(w, emptyFeed)
	}))
	t.Cleanup(feed.Close)

	t.Setenv("DMDATA_API_KEY", "")
	t.Setenv("PUBSUB_PROJECT_ID", "")
	t.Setenv("ATOM_FEED_URL", feed.URL)
	t.Setenv("ATOM_INTERVAL", "1h")
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// listenLoopback は 127.0.0.1 の空きポートを 1 つ掴む。
func listenLoopback(t *testing.T) (net.Listener, string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, port, err := net.SplitHostPort(ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	return ln, port
}

// waitHealthz は /healthz が応答を返す (= 待ち受けが立っている) まで待つ。
// 受信実績が無いので 503 が返るが、ここで見たいのは待ち受けの有無だけ。
func waitHealthz(t *testing.T, port string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	// 応答が止まったまま繋がったままになると deadline を超えて待ち続けるため、
	// 要求側にも上限を持たせる
	client := &http.Client{Timeout: time.Second}
	for time.Now().Before(deadline) {
		resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
		if err == nil {
			_ = resp.Body.Close()
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("ヘルスチェックが立ち上がらない")
}

// ListenAndServe は Shutdown されるまで戻らない。待ち受けを畳む前に listenErr を
// 待つと、SIGTERM を受けても run が戻らず graceful shutdown できなくなる。
func TestRunShutsDownOnContextCancel(t *testing.T) {
	setupEnv(t)
	ln, port := listenLoopback(t)
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PORT", port)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- run(ctx, discardLogger()) }()

	waitHealthz(t, port)
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("run() = %v, want context.Canceled", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("run が戻らない")
	}
}

// 待ち受けに失敗したまま購読を続けると、監視不能な subscriber が警報を配信し続ける。
func TestRunFailsWhenHealthPortIsBusy(t *testing.T) {
	setupEnv(t)
	ln, port := listenLoopback(t)
	defer func() { _ = ln.Close() }()
	t.Setenv("PORT", port)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- run(ctx, discardLogger()) }()

	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "ヘルスチェックの待ち受けに失敗した") {
			t.Errorf("run() = %v, want 待ち受け失敗", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("待ち受けに失敗しても run が戻らない")
	}
}

// ゼロ以下の期間を素通しすると設定ミスが黙って通る。DEDUP_TTL が 0 なら同じ電文を
// 両経路から二重配信し、HEALTH_MAX_SILENCE が 0 なら受信していても healthy にならない。
func TestEnvDurationRejectsNonPositiveAndBroken(t *testing.T) {
	const fallback = 6 * time.Hour
	for _, tc := range []struct {
		value string
		want  time.Duration
	}{
		{"", fallback},
		{"0", fallback},
		{"0s", fallback},
		{"-1s", fallback},
		{"どうかしている", fallback},
		{"90s", 90 * time.Second},
	} {
		t.Run(tc.value, func(t *testing.T) {
			t.Setenv("TENDENKO_TEST_DURATION", tc.value)
			if got := envDuration("TENDENKO_TEST_DURATION", fallback); got != tc.want {
				t.Errorf("envDuration(%q) = %v, want %v", tc.value, got, tc.want)
			}
		})
	}
}
