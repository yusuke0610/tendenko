// Package pkgwriter は地域パッケージの region.sqlite を書き出す (スキーマは ADR-0003)。
package pkgwriter

import (
	"database/sql"
	"fmt"
	"math"
	"time"

	_ "modernc.org/sqlite"
)

type NodeRow struct {
	ID       int64
	Lat, Lon float64
	ElevM    float64 // NaN = データなし → NULL
}

type EdgeRow struct {
	From, To   int64
	LengthM    float64
	Grade      float64 // 標高差 / 距離 (From→To)。逆向きは端末側で符号反転
	BearingDeg float64
	Flags      uint32
}

type ShelterRow struct {
	Name     string
	Lat, Lon float64
	ElevM    float64 // NaN = データなし → NULL
}

const schema = `
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE nodes (
  id INTEGER PRIMARY KEY,
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  elev_m REAL
);
-- エッジは無向で 1 行ずつ収載。端末ローダーが逆向き (grade 符号反転、bearing+180°) を展開する。
CREATE TABLE edges (
  from_id INTEGER NOT NULL REFERENCES nodes(id),
  to_id INTEGER NOT NULL REFERENCES nodes(id),
  length_m REAL NOT NULL,
  grade REAL NOT NULL,
  bearing_deg REAL NOT NULL,
  flags INTEGER NOT NULL
);
-- 指定緊急避難場所 (災害種別: 津波)。shelterdata パッケージが読み込む。
CREATE TABLE shelters (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  elev_m REAL
);
`

// Write は region.sqlite を新規作成する。既存ファイルがあれば失敗する。
func Write(path, meshCode, sourceNote string, nodes []NodeRow, edges []EdgeRow, shelters []ShelterRow) error {
	db, err := sql.Open("sqlite", "file:"+path+"?mode=rwc&_pragma=journal_mode(OFF)&_pragma=synchronous(OFF)")
	if err != nil {
		return err
	}
	defer db.Close()

	if _, err := db.Exec(schema); err != nil {
		return fmt.Errorf("pkgwriter: schema: %w", err)
	}

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	insNode, err := tx.Prepare("INSERT INTO nodes (id, lat, lon, elev_m) VALUES (?, ?, ?, ?)")
	if err != nil {
		return err
	}
	for _, n := range nodes {
		elev := any(n.ElevM)
		if math.IsNaN(n.ElevM) {
			elev = nil
		}
		if _, err := insNode.Exec(n.ID, n.Lat, n.Lon, elev); err != nil {
			return fmt.Errorf("pkgwriter: node %d: %w", n.ID, err)
		}
	}

	insEdge, err := tx.Prepare("INSERT INTO edges (from_id, to_id, length_m, grade, bearing_deg, flags) VALUES (?, ?, ?, ?, ?, ?)")
	if err != nil {
		return err
	}
	for _, e := range edges {
		if _, err := insEdge.Exec(e.From, e.To, e.LengthM, e.Grade, e.BearingDeg, e.Flags); err != nil {
			return fmt.Errorf("pkgwriter: edge %d→%d: %w", e.From, e.To, err)
		}
	}

	insShelter, err := tx.Prepare("INSERT INTO shelters (name, lat, lon, elev_m) VALUES (?, ?, ?, ?)")
	if err != nil {
		return err
	}
	for _, s := range shelters {
		elev := any(s.ElevM)
		if math.IsNaN(s.ElevM) {
			elev = nil
		}
		if _, err := insShelter.Exec(s.Name, s.Lat, s.Lon, elev); err != nil {
			return fmt.Errorf("pkgwriter: shelter %q: %w", s.Name, err)
		}
	}

	meta := map[string]string{
		"schema_version":   "1",
		"mesh":             meshCode,
		"generated_at":     time.Now().UTC().Format(time.RFC3339),
		"source":           sourceNote,
		"edges_undirected": "true",
	}
	for k, v := range meta {
		if _, err := tx.Exec("INSERT INTO meta (key, value) VALUES (?, ?)", k, v); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	_, err = db.Exec("CREATE INDEX idx_edges_from ON edges(from_id); CREATE INDEX idx_edges_to ON edges(to_id);")
	return err
}
