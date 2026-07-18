// build-package は OSM・浸水想定ポリゴン・指定緊急避難場所・DEM から
// オフライン用の地域パッケージを生成する。日次〜週次バッチ。
// 分割単位は 2 次メッシュ (沿岸のみ)、出力は region-<meshcode>.sqlite + tiles-<meshcode>.mbtiles (ADR-0003)。
// NFR-04: 1 地域パッケージ < 150MB / 同梱最小データセット < 50MB。
//
// TODO (まず沿岸 1 メッシュの垂直スライスでサイズ・生成時間を実測する):
//   - 対象メッシュ列挙 (浸水想定区域と交差 or 海岸線バッファ内の 2 次メッシュ)
//   - osmium でメッシュ抽出 → nodes/edges 構築、DEM の標高と浸水ポリゴン交差を属性として焼き込み
//   - region.sqlite 生成 (nodes / edges / shelters / meta — スキーマは ADR-0003)
//   - tilemaker で MBTiles 生成
//   - manifest (JSON) 生成 → GCS アップロード (バージョン・ハッシュ・生成日時で差分 DL を支える)
package main

import "fmt"

func main() {
	fmt.Println("tendenko build-package: not implemented yet")
}
