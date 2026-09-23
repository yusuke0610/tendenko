package alert

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/yusuke0610/tendenko/server/internal/jmaxml"
)

func TestFromTelegram(t *testing.T) {
	jst := time.FixedZone("JST", 9*60*60)
	arrival := time.Date(2026, 9, 8, 21, 50, 0, 0, jst)
	tel := jmaxml.Telegram{
		Type:        "VTSE41",
		Kind:        jmaxml.KindTsunamiAlert,
		EventID:     "20260908213000",
		Serial:      "1",
		InfoType:    "発表",
		ReportedAt:  time.Date(2026, 9, 8, 21, 34, 0, 0, jst),
		Headline:    "大津波警報を発表しました。",
		MaxCategory: "大津波警報",
		Areas: []jmaxml.Area{
			{Code: "212", Name: "岩手県", Category: "大津波警報", FirstHeightAt: arrival, MaxHeightM: 10},
			{Code: "222", Name: "宮城県", Category: "津波注意報"},
		},
	}
	received := time.Date(2026, 9, 8, 21, 34, 2, 0, jst)

	m := FromTelegram(tel, SourceDMDATA, received)
	if m.Version != Version || m.Kind != "tsunami_alert" || m.Source != SourceDMDATA {
		t.Errorf("message = %+v", m)
	}
	if len(m.Areas) != 2 {
		t.Fatalf("Areas = %d, want 2", len(m.Areas))
	}
	if m.Areas[0].FirstHeightAt == nil || !m.Areas[0].FirstHeightAt.Equal(arrival) {
		t.Errorf("Areas[0].FirstHeightAt = %v", m.Areas[0].FirstHeightAt)
	}
	// 到達予想時刻を持たない地域はフィールドごと省略する
	if m.Areas[1].FirstHeightAt != nil {
		t.Errorf("Areas[1].FirstHeightAt = %v, want nil", m.Areas[1].FirstHeightAt)
	}
}

// Kind は app 側 EvacuationPhase.swift の Telegram enum と 1 対 1 に対応する。
// ここが崩れると端末のフェーズ遷移が動かないので、値を固定して守る。
func TestKindMatchesAppTelegramEnum(t *testing.T) {
	for _, tc := range []struct {
		kind jmaxml.Kind
		want string
	}{
		{jmaxml.KindEEW, "eew"},
		{jmaxml.KindTsunamiAlert, "tsunami_alert"},
		{jmaxml.KindAllClear, "all_clear"},
		{jmaxml.KindTsunamiInfo, "tsunami_info"},
	} {
		m := FromTelegram(jmaxml.Telegram{Kind: tc.kind}, SourceDMDATA, time.Now())
		if m.Kind != tc.want {
			t.Errorf("Kind = %q, want %q", m.Kind, tc.want)
		}
	}
}

func TestMessageJSONShape(t *testing.T) {
	m := FromTelegram(jmaxml.Telegram{
		Type:       "VXSE43",
		Kind:       jmaxml.KindEEW,
		EventID:    "20260908213000",
		ReportedAt: time.Date(2026, 9, 8, 12, 30, 10, 0, time.UTC),
	}, SourceJMAAtom, time.Date(2026, 9, 8, 12, 30, 12, 0, time.UTC))

	data, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	const want = `{"version":1,"kind":"eew","telegramType":"VXSE43","eventId":"20260908213000",` +
		`"reportedAt":"2026-09-08T12:30:10Z","receivedAt":"2026-09-08T12:30:12Z","source":"jma_atom"}`
	if string(data) != want {
		t.Errorf("json =\n%s\nwant\n%s", data, want)
	}
}
