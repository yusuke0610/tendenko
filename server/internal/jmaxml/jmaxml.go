// Package jmaxml は気象庁防災情報 XML の電文を解析する。
//
// 一次経路 (DMDATA.jp の WebSocket) と二次経路 (気象庁 ATOM フィード) の双方から
// 同じ気象庁 XML が届くため、パーサはこの 1 つに集約する (ADR-0008)。
// 対象電文は requirements.md §3.2 の 4 種のみで、それ以外は ErrUnsupportedType で捨てる。
//
// 注意: 種別コードや解除の表現は一次情報 (気象庁「電文毎の解説資料」) と未照合である。
// 詳細と照合が済むまで本番投入しない旨は ADR-0008 および testdata/README.md を参照。
package jmaxml

import (
	"encoding/xml"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Kind は電文の分類。app 側 EvacuationPhase.swift の Telegram enum と 1 対 1 に対応する。
// フェーズ遷移そのものは端末の責務であり、サーバーは分類までしか行わない (ADR-0008)。
type Kind string

const (
	KindEEW          Kind = "eew"
	KindTsunamiAlert Kind = "tsunami_alert"
	KindAllClear     Kind = "all_clear"
	KindTsunamiInfo  Kind = "tsunami_info"
)

var (
	// ErrUnsupportedType は requirements §3.2 の対象外電文。購読を止めずに捨てる。
	ErrUnsupportedType = errors.New("jmaxml: 対象外の電文種別")
	// ErrNotOperational は訓練・試験電文。実警報として流してはならない。
	ErrNotOperational = errors.New("jmaxml: 訓練・試験電文")
)

// Area は電文が対象とする地域 1 件。Stage 1 の全件送出では使わないが、
// Stage 2 の地域別送出 (ADR-0001) のために最初から取り出しておく。
type Area struct {
	Code string
	Name string
	// Category は津波電文の警戒レベル (大津波警報・津波警報・津波注意報・津波予報)。
	Category string
	// FirstHeightAt は津波の到達予想時刻 (FR-17)。未提供ならゼロ値。
	FirstHeightAt time.Time
	// MaxHeightM は予想される津波の高さ (m)。未提供・非数値なら 0。
	MaxHeightM float64
	// ForecastIntensity は EEW の予測震度。
	ForecastIntensity string
}

type Telegram struct {
	Type       string // VTSE41 等。伝送路が与える電文種別コード
	Kind       Kind
	EventID    string
	Serial     string
	InfoType   string // 発表 / 訂正 / 遅延 / 取消
	InfoKind   string
	ReportedAt time.Time
	Headline   string
	// MaxCategory は津波電文で最も重い警戒レベル。全解除なら空。
	MaxCategory string
	// MaxIntensity は EEW の最大予測震度。
	MaxIntensity string
	Areas        []Area
}

// DedupKey は電文の同一性キー。一次経路と二次経路の双方に存在する気象庁ヘッダ項目
// だけで構成し、DMDATA 固有の電文 ID は使わない (ADR-0008)。
func (t Telegram) DedupKey() string {
	return strings.Join([]string{
		t.Type, t.EventID, t.InfoKind, t.Serial, t.ReportedAt.UTC().Format(time.RFC3339),
	}, "|")
}

// 警戒レベルの重さ。解除・津波なしは 0 (rank に載せない)。
var categoryRank = map[string]int{
	"津波予報":  1,
	"津波注意報": 2,
	"津波警報":  3,
	"大津波警報": 4,
}

type report struct {
	Control struct {
		Title  string `xml:"Title"`
		Status string `xml:"Status"`
	} `xml:"Control"`
	Head struct {
		Title          string `xml:"Title"`
		ReportDateTime string `xml:"ReportDateTime"`
		EventID        string `xml:"EventID"`
		InfoType       string `xml:"InfoType"`
		Serial         string `xml:"Serial"`
		InfoKind       string `xml:"InfoKind"`
		Headline       struct {
			Text string `xml:"Text"`
		} `xml:"Headline"`
	} `xml:"Head"`
	Body struct {
		Tsunami struct {
			Forecast   tsunamiItems `xml:"Forecast"`
			Estimation tsunamiItems `xml:"Estimation"`
		} `xml:"Tsunami"`
		Intensity struct {
			Forecast struct {
				ForecastInt forecastInt `xml:"ForecastInt"`
				Areas       []struct {
					Name        string      `xml:"Name"`
					Code        string      `xml:"Code"`
					ForecastInt forecastInt `xml:"ForecastInt"`
				} `xml:"Area"`
			} `xml:"Forecast"`
		} `xml:"Intensity"`
	} `xml:"Body"`
}

type forecastInt struct {
	From string `xml:"From"`
	To   string `xml:"To"`
}

type tsunamiItems struct {
	Items []struct {
		Area struct {
			Name string `xml:"Name"`
			Code string `xml:"Code"`
		} `xml:"Area"`
		Category struct {
			Kind struct {
				Name string `xml:"Name"`
			} `xml:"Kind"`
		} `xml:"Category"`
		FirstHeight struct {
			ArrivalTime string `xml:"ArrivalTime"`
		} `xml:"FirstHeight"`
		MaxHeight struct {
			TsunamiHeight string `xml:"TsunamiHeight"`
		} `xml:"MaxHeight"`
	} `xml:"Item"`
}

// Parse は電文種別コード (VTSE41 等) と気象庁 XML の本文から Telegram を組み立てる。
// 種別コードは XML 本文には含まれないため、伝送路 (DMDATA の head.type、
// ATOM のエントリ URL) から与える。
func Parse(telegramType string, data []byte) (Telegram, error) {
	switch telegramType {
	case "VXSE43", "VXSE45", "VTSE41", "VTSE51":
	default:
		return Telegram{}, fmt.Errorf("%w: %s", ErrUnsupportedType, telegramType)
	}

	var r report
	if err := xml.Unmarshal(data, &r); err != nil {
		return Telegram{}, fmt.Errorf("jmaxml: %s: %w", telegramType, err)
	}
	// Status は必須項目。空は「運用電文だと確認できていない」ことを意味するので、
	// 実警報として流さない (未知の構造の電文を配信しないための保険でもある)
	if s := r.Control.Status; s != "通常" {
		return Telegram{}, fmt.Errorf("%w: %q", ErrNotOperational, s)
	}

	// EventID と ReportDateTime は同一性キー (ADR-0008) の骨格。どちらかが欠けると
	// 別個の電文が同じキーに潰れ、2 通目以降が重複として捨てられる。ReportDateTime を
	// 解釈できないときも同じで、ゼロ値 (西暦 1 年) のまま配信してはならない。
	//
	// Serial と InfoKind をここで必須にしないのは、気象庁 XML でこれらが省略されうるかを
	// 一次情報で確認できていないためである。EventID + ReportedAt があればキーは潰れないので、
	// 空の続報番号 1 つで実際の津波警報を落とす方が高くつく (ADR-0008 の照合待ち項目)。
	if r.Head.EventID == "" {
		return Telegram{}, errors.New("jmaxml: Head/EventID が空")
	}
	reportedAt, err := time.Parse(time.RFC3339, r.Head.ReportDateTime)
	if err != nil {
		return Telegram{}, fmt.Errorf("jmaxml: Head/ReportDateTime を解釈できない: %q", r.Head.ReportDateTime)
	}

	tel := Telegram{
		Type:       telegramType,
		EventID:    r.Head.EventID,
		Serial:     r.Head.Serial,
		InfoType:   r.Head.InfoType,
		InfoKind:   r.Head.InfoKind,
		ReportedAt: reportedAt,
		Headline:   r.Head.Headline.Text,
	}

	switch telegramType {
	case "VXSE43", "VXSE45":
		tel.Kind = KindEEW
		tel.MaxIntensity = r.Body.Intensity.Forecast.ForecastInt.From
		for _, a := range r.Body.Intensity.Forecast.Areas {
			tel.Areas = append(tel.Areas, Area{
				Code:              a.Code,
				Name:              a.Name,
				ForecastIntensity: a.ForecastInt.From,
			})
		}
	case "VTSE41":
		tel.Areas = tsunamiAreas(r.Body.Tsunami.Forecast)
		tel.MaxCategory = maxCategory(tel.Areas)
		// 解除と判断するのは、電文そのものの取消か、全地域の解除を実際に確認できたときだけ。
		// MaxCategory が空であることを解除の証拠に使ってはならない: maxCategory は既知の
		// 4 カテゴリ以外をすべて空で返すため、Forecast を取り出せなかった電文や表記の
		// 違う電文まで「全解除」として配信してしまう。カテゴリの表記は一次情報と未照合
		// (ADR-0008) なので、判定できない電文は解析エラーにして落とす。実際の警報を
		// 解除として流すのは、このプロダクトで最も避けるべき事故である。
		switch {
		case r.Head.InfoType == "取消" || allAreasCleared(tel.Areas):
			tel.Kind = KindAllClear
		case tel.MaxCategory != "":
			tel.Kind = KindTsunamiAlert
		default:
			return Telegram{}, fmt.Errorf("jmaxml: VTSE41 の警戒レベルを判定できない (地域 %d 件)", len(tel.Areas))
		}
	case "VTSE51":
		tel.Kind = KindTsunamiInfo
		items := r.Body.Tsunami.Estimation
		if len(items.Items) == 0 {
			items = r.Body.Tsunami.Forecast
		}
		tel.Areas = tsunamiAreas(items)
	}
	return tel, nil
}

func tsunamiAreas(items tsunamiItems) []Area {
	var areas []Area
	for _, it := range items.Items {
		a := Area{
			Code:          it.Area.Code,
			Name:          it.Area.Name,
			Category:      it.Category.Kind.Name,
			FirstHeightAt: parseTime(it.FirstHeight.ArrivalTime),
		}
		// description が "10m超" のような非数値のこともあるため、失敗は 0 のままにする
		if h, err := strconv.ParseFloat(strings.TrimSpace(it.MaxHeight.TsunamiHeight), 64); err == nil {
			a.MaxHeightM = h
		}
		areas = append(areas, a)
	}
	return areas
}

// maxCategory は最も重い警戒レベルを返す。全地域が解除・津波なしなら空を返す。
func maxCategory(areas []Area) string {
	best, bestRank := "", 0
	for _, a := range areas {
		if rank := categoryRank[a.Category]; rank > bestRank {
			best, bestRank = a.Category, rank
		}
	}
	return best
}

// allAreasCleared は全地域が解除カテゴリかを返す。地域が 1 件も無い場合は false:
// 空の地域一覧を全解除と読むと、構造の異なる電文や取り出しに失敗した電文が
// 「解除」になってしまう。
func allAreasCleared(areas []Area) bool {
	if len(areas) == 0 {
		return false
	}
	for _, a := range areas {
		if !clearedCategory(a.Category) {
			return false
		}
	}
	return true
}

// clearedCategory は解除を表す警戒レベルかを返す。
//
// 解除の実際の表記は一次情報 (気象庁「電文毎の解説資料」) と未照合である (ADR-0008)。
// 「津波警報解除」「津波注意報解除」のような表記の揺れを取りこぼさないため部分一致で見る。
// 津波の心配がないことを示す「津波なし」も解除として扱う。
func clearedCategory(name string) bool {
	name = strings.TrimSpace(name)
	return name == "津波なし" || strings.Contains(name, "解除")
}

func parseTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t
}
