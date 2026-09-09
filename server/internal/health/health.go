// Package health は subscriber の生存判定を提供する。
//
// ADR-0001 が明示するとおり、判定は「プロセスが生きている」ことではなく
// 「電文の入手経路が生きていて、直近 N 分以内に何かを受信している」ことで行う。
// プロセスだけ生きていて WS が死んでいる状態は、このプロダクトでは全損に等しい。
package health

import (
	"encoding/json"
	"net/http"
	"time"
)

// Probe は電文の入手経路 1 本の状態を読む。
type Probe struct {
	Name string
	// Live は経路が機能しているか (WS なら接続中、ATOM ならポーリング成功中)。
	Live func() bool
	// LastActivity は最後に受信・取得に成功した時刻。
	LastActivity func() time.Time
}

type ProbeStatus struct {
	Name         string    `json:"name"`
	Live         bool      `json:"live"`
	LastActivity time.Time `json:"lastActivity,omitzero"`
	SilentFor    string    `json:"silentFor,omitempty"`
}

type Status struct {
	Healthy bool          `json:"healthy"`
	Probes  []ProbeStatus `json:"probes"`
}

type Checker struct {
	probes     []Probe
	maxSilence time.Duration
	now        func() time.Time
}

// New は maxSilence 以内に受信のある経路が 1 本でもあれば healthy とする判定器を作る。
// 一次経路が落ちても二次経路が生きていれば縮退運用として動けるため、
// 「いずれか 1 本」を条件にする。
func New(maxSilence time.Duration, probes ...Probe) *Checker {
	return &Checker{probes: probes, maxSilence: maxSilence, now: time.Now}
}

func (c *Checker) Status() Status {
	now := c.now()
	st := Status{Probes: make([]ProbeStatus, 0, len(c.probes))}
	for _, p := range c.probes {
		last := p.LastActivity()
		live := p.Live()
		ps := ProbeStatus{Name: p.Name, Live: live, LastActivity: last}
		if !last.IsZero() {
			ps.SilentFor = now.Sub(last).Round(time.Second).String()
		}
		if live && !last.IsZero() && now.Sub(last) <= c.maxSilence {
			st.Healthy = true
		}
		st.Probes = append(st.Probes, ps)
	}
	return st
}

func (c *Checker) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	st := c.Status()
	w.Header().Set("Content-Type", "application/json")
	if !st.Healthy {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	_ = json.NewEncoder(w).Encode(st)
}
