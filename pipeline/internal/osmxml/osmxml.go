// Package osmxml は OSM XML (.osm) のストリーミングパースを提供する。
// osmium extract で 2 次メッシュに切り出した後のファイルを想定しており、
// メッシュ規模 (数十 MB) なら全ノードをメモリに載せて問題ない。
package osmxml

import (
	"encoding/xml"
	"fmt"
	"io"
	"strconv"
)

type Node struct {
	ID       int64
	Lat, Lon float64
}

type Way struct {
	ID      int64
	NodeIDs []int64
	Tags    map[string]string
}

// Parse は nodes と、keepWay が true を返した way を読み込む。
func Parse(r io.Reader, keepWay func(tags map[string]string) bool) (map[int64]Node, []Way, error) {
	nodes := make(map[int64]Node)
	var ways []Way

	dec := xml.NewDecoder(r)
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, nil, fmt.Errorf("osmxml: %w", err)
		}
		se, ok := tok.(xml.StartElement)
		if !ok {
			continue
		}
		switch se.Name.Local {
		case "node":
			n, err := parseNode(se)
			if err != nil {
				return nil, nil, err
			}
			nodes[n.ID] = n
			if err := dec.Skip(); err != nil {
				return nil, nil, fmt.Errorf("osmxml: node %d: %w", n.ID, err)
			}
		case "way":
			w, err := parseWay(dec, se)
			if err != nil {
				return nil, nil, err
			}
			if keepWay(w.Tags) {
				ways = append(ways, w)
			}
		case "relation":
			if err := dec.Skip(); err != nil {
				return nil, nil, fmt.Errorf("osmxml: relation: %w", err)
			}
		}
	}
	return nodes, ways, nil
}

func parseNode(se xml.StartElement) (Node, error) {
	var n Node
	for _, a := range se.Attr {
		var err error
		switch a.Name.Local {
		case "id":
			n.ID, err = strconv.ParseInt(a.Value, 10, 64)
		case "lat":
			n.Lat, err = strconv.ParseFloat(a.Value, 64)
		case "lon":
			n.Lon, err = strconv.ParseFloat(a.Value, 64)
		}
		if err != nil {
			return n, fmt.Errorf("osmxml: node attr %s: %w", a.Name.Local, err)
		}
	}
	return n, nil
}

func parseWay(dec *xml.Decoder, start xml.StartElement) (Way, error) {
	w := Way{Tags: map[string]string{}}
	for _, a := range start.Attr {
		if a.Name.Local == "id" {
			id, err := strconv.ParseInt(a.Value, 10, 64)
			if err != nil {
				return w, fmt.Errorf("osmxml: way id: %w", err)
			}
			w.ID = id
		}
	}
	for {
		tok, err := dec.Token()
		if err != nil {
			return w, fmt.Errorf("osmxml: way %d: %w", w.ID, err)
		}
		switch t := tok.(type) {
		case xml.StartElement:
			switch t.Name.Local {
			case "nd":
				for _, a := range t.Attr {
					if a.Name.Local == "ref" {
						ref, err := strconv.ParseInt(a.Value, 10, 64)
						if err != nil {
							return w, fmt.Errorf("osmxml: way %d nd ref: %w", w.ID, err)
						}
						w.NodeIDs = append(w.NodeIDs, ref)
					}
				}
			case "tag":
				var k, v string
				for _, a := range t.Attr {
					switch a.Name.Local {
					case "k":
						k = a.Value
					case "v":
						v = a.Value
					}
				}
				w.Tags[k] = v
			}
			if err := dec.Skip(); err != nil {
				return w, fmt.Errorf("osmxml: way %d: %w", w.ID, err)
			}
		case xml.EndElement:
			if t.Name.Local == "way" {
				return w, nil
			}
		}
	}
}
