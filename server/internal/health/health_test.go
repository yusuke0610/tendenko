package health

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func probe(name string, live bool, last time.Time) Probe {
	return Probe{
		Name:         name,
		Live:         func() bool { return live },
		LastActivity: func() time.Time { return last },
	}
}

func TestStatus(t *testing.T) {
	now := time.Date(2026, 9, 8, 21, 34, 0, 0, time.UTC)
	for _, tc := range []struct {
		name   string
		probes []Probe
		want   bool
	}{
		{"接続中かつ受信あり", []Probe{probe("dmdata", true, now.Add(-time.Minute))}, true},
		// ADR-0001: プロセス生存では不十分。接続していても無音が続けば不健全
		{"接続中だが長時間無音", []Probe{probe("dmdata", true, now.Add(-time.Hour))}, false},
		{"切断中", []Probe{probe("dmdata", false, now.Add(-time.Minute))}, false},
		{"未受信", []Probe{probe("dmdata", true, time.Time{})}, false},
		// 一次経路が落ちても二次経路で縮退運用できていれば healthy
		{"一次断・二次生存", []Probe{
			probe("dmdata", false, now.Add(-time.Hour)),
			probe("jma_atom", true, now.Add(-30*time.Second)),
		}, true},
		{"経路なし", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := New(5*time.Minute, tc.probes...)
			c.now = func() time.Time { return now }
			if got := c.Status().Healthy; got != tc.want {
				t.Errorf("Healthy = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestServeHTTP(t *testing.T) {
	now := time.Date(2026, 9, 8, 21, 34, 0, 0, time.UTC)
	c := New(5*time.Minute, probe("dmdata", true, now.Add(-time.Minute)))
	c.now = func() time.Time { return now }

	rec := httptest.NewRecorder()
	c.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
	var st Status
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatal(err)
	}
	if !st.Healthy || len(st.Probes) != 1 || st.Probes[0].Name != "dmdata" {
		t.Errorf("body = %+v", st)
	}
}

// 不健全なら 503 を返す。Cloud Run にインスタンスを差し替えさせるため。
func TestServeHTTPUnhealthy(t *testing.T) {
	c := New(5*time.Minute, probe("dmdata", false, time.Time{}))
	rec := httptest.NewRecorder()
	c.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", rec.Code)
	}
}
