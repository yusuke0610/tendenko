// Package alert は subscriber が fanout へ渡すメッセージ契約を定義する (ADR-0008)。
//
// この JSON がサーバー間の唯一の境界であり、最終的に app 側 EvacuationPhase.swift の
// Telegram enum に対応する。したがって Kind の値を変えるときはアプリ側と同時に直す。
//
// フェーズ遷移はここでは行わない。EvacuationPhase.transitioned(on:) は端末側にあり、
// 「サーバー全損でも手動起動で案内できる」(NFR-06) がその前提である。
package alert

import (
	"time"

	"github.com/yusuke0610/tendenko/server/internal/jmaxml"
)

// Version はメッセージ契約のバージョン。非互換変更のたびに上げる。
const Version = 1

// Source は電文の入手経路。障害時にどちらの経路で拾えたかを追えるようにする。
type Source string

const (
	SourceDMDATA  Source = "dmdata"
	SourceJMAAtom Source = "jma_atom"
)

type Area struct {
	Code string `json:"code,omitempty"`
	Name string `json:"name,omitempty"`
	// Category は津波電文の警戒レベル (大津波警報 等)。
	Category string `json:"category,omitempty"`
	// FirstHeightAt は津波の到達予想時刻 (FR-17)。未提供なら省略する。
	FirstHeightAt *time.Time `json:"firstHeightAt,omitempty"`
	MaxHeightM    float64    `json:"maxHeightM,omitempty"`
	// ForecastIntensity は EEW の予測震度。
	ForecastIntensity string `json:"forecastIntensity,omitempty"`
}

type Message struct {
	Version      int       `json:"version"`
	Kind         string    `json:"kind"`
	TelegramType string    `json:"telegramType"`
	EventID      string    `json:"eventId"`
	Serial       string    `json:"serial,omitempty"`
	InfoType     string    `json:"infoType,omitempty"`
	ReportedAt   time.Time `json:"reportedAt"`
	ReceivedAt   time.Time `json:"receivedAt"`
	Source       Source    `json:"source"`
	MaxCategory  string    `json:"maxCategory,omitempty"`
	MaxIntensity string    `json:"maxIntensity,omitempty"`
	Headline     string    `json:"headline,omitempty"`
	// Areas は Stage 1 の全件送出では使わないが、Stage 2 の地域別送出 (ADR-0001) の
	// ために最初から載せる。後からペイロードを広げるとアプリ側の互換対応が要る。
	Areas []Area `json:"areas,omitempty"`
}

// FromTelegram は解析済み電文を配信メッセージに正規化する。
func FromTelegram(t jmaxml.Telegram, src Source, receivedAt time.Time) Message {
	m := Message{
		Version:      Version,
		Kind:         string(t.Kind),
		TelegramType: t.Type,
		EventID:      t.EventID,
		Serial:       t.Serial,
		InfoType:     t.InfoType,
		ReportedAt:   t.ReportedAt,
		ReceivedAt:   receivedAt,
		Source:       src,
		MaxCategory:  t.MaxCategory,
		MaxIntensity: t.MaxIntensity,
		Headline:     t.Headline,
	}
	for _, a := range t.Areas {
		area := Area{
			Code:              a.Code,
			Name:              a.Name,
			Category:          a.Category,
			MaxHeightM:        a.MaxHeightM,
			ForecastIntensity: a.ForecastIntensity,
		}
		if !a.FirstHeightAt.IsZero() {
			at := a.FirstHeightAt
			area.FirstHeightAt = &at
		}
		m.Areas = append(m.Areas, area)
	}
	return m
}
