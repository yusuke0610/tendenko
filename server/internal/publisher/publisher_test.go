package publisher

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/yusuke0610/tendenko/server/internal/alert"
)

// Pub/Sub 実装のテストにはエミュレータが要るためここでは扱わない。
// 送出経路の検証は #24 の残課題 (実 GCP 接続) 側で行う。
func TestStdoutPublish(t *testing.T) {
	var buf bytes.Buffer
	p := NewStdout(&buf)

	m := alert.Message{Version: 1, Kind: "tsunami_alert", TelegramType: "VTSE41", EventID: "e1"}
	if err := p.Publish(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	if err := p.Publish(context.Background(), alert.Message{Kind: "all_clear"}); err != nil {
		t.Fatal(err)
	}

	// 1 行 1 メッセージ (ログ収集でそのまま扱えるように)
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("行数 = %d, want 2", len(lines))
	}
	var got alert.Message
	if err := json.Unmarshal([]byte(lines[0]), &got); err != nil {
		t.Fatal(err)
	}
	if got.Kind != "tsunami_alert" || got.EventID != "e1" {
		t.Errorf("got = %+v", got)
	}
}

func TestStdoutConcurrent(t *testing.T) {
	var buf bytes.Buffer
	p := NewStdout(&buf)

	done := make(chan struct{})
	for range 20 {
		go func() {
			defer func() { done <- struct{}{} }()
			_ = p.Publish(context.Background(), alert.Message{Kind: "eew", ReportedAt: time.Now()})
		}()
	}
	for range 20 {
		<-done
	}
	if n := len(strings.Split(strings.TrimSpace(buf.String()), "\n")); n != 20 {
		t.Errorf("行数 = %d, want 20", n)
	}
}
