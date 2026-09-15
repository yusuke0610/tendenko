package jmaxml

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func load(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestParseTsunamiAlert(t *testing.T) {
	tel, err := Parse("VTSE41", load(t, "vtse41-alert.xml"))
	if err != nil {
		t.Fatal(err)
	}
	if tel.Kind != KindTsunamiAlert {
		t.Errorf("Kind = %q, want %q", tel.Kind, KindTsunamiAlert)
	}
	if tel.EventID != "20260908213000" || tel.Serial != "1" || tel.InfoType != "発表" {
		t.Errorf("header = %+v", tel)
	}
	want := time.Date(2026, 9, 8, 21, 34, 0, 0, time.FixedZone("JST", 9*60*60))
	if !tel.ReportedAt.Equal(want) {
		t.Errorf("ReportedAt = %v, want %v", tel.ReportedAt, want)
	}
	// 複数地域のうち最も重い警戒レベルを採る
	if tel.MaxCategory != "大津波警報" {
		t.Errorf("MaxCategory = %q, want 大津波警報", tel.MaxCategory)
	}
	if len(tel.Areas) != 2 {
		t.Fatalf("Areas = %d, want 2", len(tel.Areas))
	}
	iwate := tel.Areas[0]
	if iwate.Name != "岩手県" || iwate.Code != "212" || iwate.Category != "大津波警報" {
		t.Errorf("Areas[0] = %+v", iwate)
	}
	if iwate.MaxHeightM != 10 {
		t.Errorf("Areas[0].MaxHeightM = %v, want 10", iwate.MaxHeightM)
	}
	if iwate.FirstHeightAt.IsZero() {
		t.Error("Areas[0].FirstHeightAt is zero")
	}
	if tel.Areas[1].Category != "津波注意報" {
		t.Errorf("Areas[1].Category = %q", tel.Areas[1].Category)
	}
}

func TestParseAllClear(t *testing.T) {
	tel, err := Parse("VTSE41", load(t, "vtse41-allclear.xml"))
	if err != nil {
		t.Fatal(err)
	}
	// 全地域が解除なら VTSE41 でも all_clear に分類する
	if tel.Kind != KindAllClear {
		t.Errorf("Kind = %q, want %q", tel.Kind, KindAllClear)
	}
	if tel.MaxCategory != "" {
		t.Errorf("MaxCategory = %q, want empty", tel.MaxCategory)
	}
}

// 訓練・試験電文を実警報として流すのは最も避けるべき事故なので、パーサの段階で落とす。
func TestParseRejectsDrill(t *testing.T) {
	_, err := Parse("VTSE41", load(t, "vtse41-drill.xml"))
	if !errors.Is(err, ErrNotOperational) {
		t.Fatalf("err = %v, want ErrNotOperational", err)
	}
}

// Status が空なのは「運用電文だと確認できていない」状態。構造が想定と違う電文を
// 実警報として配信しないよう、通常以外はすべて落とす。
func TestParseRejectsMissingStatus(t *testing.T) {
	const noStatus = `<Report xmlns="http://xml.kishou.go.jp/jmaxml1/">
  <Control><Title>津波警報・注意報・予報</Title></Control>
  <Head xmlns="http://xml.kishou.go.jp/jmaxml1/informationBasis1/"><EventID>e1</EventID></Head>
  <Body xmlns="http://xml.kishou.go.jp/jmaxml1/body/seismology1/"><Tsunami><Forecast><Item>
    <Area><Name>岩手県</Name><Code>212</Code></Area>
    <Category><Kind><Name>大津波警報</Name></Kind></Category>
  </Item></Forecast></Tsunami></Body>
</Report>`
	if _, err := Parse("VTSE41", []byte(noStatus)); !errors.Is(err, ErrNotOperational) {
		t.Fatalf("err = %v, want ErrNotOperational", err)
	}
}

func TestParseTsunamiInfo(t *testing.T) {
	tel, err := Parse("VTSE51", load(t, "vtse51-info.xml"))
	if err != nil {
		t.Fatal(err)
	}
	if tel.Kind != KindTsunamiInfo {
		t.Errorf("Kind = %q, want %q", tel.Kind, KindTsunamiInfo)
	}
	if len(tel.Areas) != 1 {
		t.Fatalf("Areas = %d, want 1", len(tel.Areas))
	}
	// FR-17 (到達予想時刻の音声反映) が使う値
	arrival := tel.Areas[0].FirstHeightAt
	want := time.Date(2026, 9, 8, 21, 50, 0, 0, time.FixedZone("JST", 9*60*60))
	if !arrival.Equal(want) {
		t.Errorf("FirstHeightAt = %v, want %v", arrival, want)
	}
}

func TestParseEEW(t *testing.T) {
	tel, err := Parse("VXSE43", load(t, "vxse43-eew.xml"))
	if err != nil {
		t.Fatal(err)
	}
	if tel.Kind != KindEEW {
		t.Errorf("Kind = %q, want %q", tel.Kind, KindEEW)
	}
	if tel.MaxIntensity != "6+" {
		t.Errorf("MaxIntensity = %q, want 6+", tel.MaxIntensity)
	}
	if len(tel.Areas) != 2 {
		t.Fatalf("Areas = %d, want 2", len(tel.Areas))
	}
	if tel.Areas[0].Name != "岩手県沿岸北部" || tel.Areas[0].ForecastIntensity != "6+" {
		t.Errorf("Areas[0] = %+v", tel.Areas[0])
	}
}

func TestParseUnsupportedType(t *testing.T) {
	// requirements §3.2 の対象外電文は、エラーで購読を止めずに黙って捨てられるようにする
	_, err := Parse("VXSE51", load(t, "vxse43-eew.xml"))
	if !errors.Is(err, ErrUnsupportedType) {
		t.Fatalf("err = %v, want ErrUnsupportedType", err)
	}
}

func TestParseMalformed(t *testing.T) {
	if _, err := Parse("VTSE41", []byte("<Report>")); err == nil {
		t.Fatal("want error for malformed XML")
	}
}

// デデュープキーは一次経路 (DMDATA) と二次経路 (ATOM) の双方に存在する
// 気象庁ヘッダ項目だけで構成する (ADR-0008)。
func TestDedupKey(t *testing.T) {
	a, err := Parse("VTSE41", load(t, "vtse41-alert.xml"))
	if err != nil {
		t.Fatal(err)
	}
	b, err := Parse("VTSE41", load(t, "vtse41-alert.xml"))
	if err != nil {
		t.Fatal(err)
	}
	if a.DedupKey() != b.DedupKey() {
		t.Errorf("same telegram gave different keys: %q vs %q", a.DedupKey(), b.DedupKey())
	}
	c, err := Parse("VTSE41", load(t, "vtse41-allclear.xml"))
	if err != nil {
		t.Fatal(err)
	}
	// 同一 EventID でも続報 (Serial) が違えば別電文
	if a.DedupKey() == c.DedupKey() {
		t.Errorf("different telegrams shared key %q", a.DedupKey())
	}
}
