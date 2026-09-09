// Package publisher は解析済みの警報メッセージを fanout へ渡す。
//
// ADR-0001 が subscriber → fanout の起動を Pub/Sub と定めている。GCP への依存は
// この 1 パッケージに閉じ込め、他は Publisher インターフェースだけを見る。
// ADR-0001 の「コストが問題になったら VM へ戻す」「実行基盤非依存に保つ」を
// 成立させるための境界である。
package publisher

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"time"

	"cloud.google.com/go/pubsub/v2"

	"github.com/yusuke0610/tendenko/server/internal/alert"
)

type Publisher interface {
	Publish(ctx context.Context, m alert.Message) error
	Close() error
}

// Stdout は Pub/Sub を設定していないときの出力先。ローカル実行と、
// GCP 未接続でもプロセスを起動して経路を確認したい場合に使う。
type Stdout struct {
	mu sync.Mutex
	w  io.Writer
}

func NewStdout(w io.Writer) *Stdout { return &Stdout{w: w} }

func (s *Stdout) Publish(_ context.Context, m alert.Message) error {
	data, err := json.Marshal(m)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err = fmt.Fprintf(s.w, "%s\n", data)
	return err
}

func (s *Stdout) Close() error { return nil }

// PubSub は Cloud Pub/Sub への送出。
type PubSub struct {
	client *pubsub.Client
	pub    *pubsub.Publisher
}

func NewPubSub(ctx context.Context, projectID, topic string) (*PubSub, error) {
	client, err := pubsub.NewClient(ctx, projectID)
	if err != nil {
		return nil, fmt.Errorf("publisher: pubsub client: %w", err)
	}
	pub := client.Publisher(topic)
	// NFR-01 (受信 → APNs 送出 p99 < 1 秒) に対してバッチ待ちは許容できない。
	// 1 件ごとに即送出する。平時の流量はゼロに近く、まとめる利点も無い。
	pub.PublishSettings.CountThreshold = 1
	pub.PublishSettings.DelayThreshold = 10 * time.Millisecond
	return &PubSub{client: client, pub: pub}, nil
}

func (p *PubSub) Publish(ctx context.Context, m alert.Message) error {
	data, err := json.Marshal(m)
	if err != nil {
		return err
	}
	// fanout が本文を解析せずに振り分けられるよう、要点は属性にも載せる
	res := p.pub.Publish(ctx, &pubsub.Message{
		Data: data,
		Attributes: map[string]string{
			"kind":         m.Kind,
			"telegramType": m.TelegramType,
			"eventId":      m.EventID,
		},
	})
	if _, err := res.Get(ctx); err != nil {
		return fmt.Errorf("publisher: publish: %w", err)
	}
	return nil
}

func (p *PubSub) Close() error {
	p.pub.Stop()
	return p.client.Close()
}
