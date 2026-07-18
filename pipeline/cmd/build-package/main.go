// build-package は OSM・浸水想定ポリゴン・指定緊急避難場所・DEM から
// オフライン用の地域パッケージを生成する。日次〜週次バッチ。
// NFR-04: 1 地域パッケージ < 150MB / 同梱最小データセット < 50MB。
//
// TODO (地域分割単位・道路グラフフォーマットは ADR-0003 で決定してから実装):
//   - osmium で地域抽出 → 道路グラフ構築 (標高コスト付与のため DEM と結合)
//   - tilemaker でオフライン地図タイル生成
//   - 国土数値情報の浸水想定・避難場所の取り込み
//   - パッケージへの更新日時埋め込み (6 ヶ月超は端末 UI で警告する要件)
//   - GCS へのアップロードと差分配信用メタデータ
package main

import "fmt"

func main() {
	fmt.Println("tendenko build-package: not implemented yet")
}
