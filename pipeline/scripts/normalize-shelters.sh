#!/bin/sh
# 国土地理院「指定緊急避難場所データ」全国 GeoJSON を、
# pipeline/internal/shelterdata が読む正規化 GeoJSON に変換する (ADR-0003)。
#
# 元データの属性は日本語キー ("指定緊急避難場所", "津波" など、災害種別ごとに
# "◎"/"" で該当有無を表す)。"津波"=="◎" の地物だけを抽出し、
# {name, tsunami:true} に正規化する。
#
# 使い方 (data/raw/shelters-all.geojson に元データを置いてから):
#   nix develop 内で: scripts/normalize-shelters.sh
#
# 出力: data/shelters-japan.geojson
set -eu

cd "$(dirname "$0")/.."
jq '{
  type: "FeatureCollection",
  features: [.features[] | select(.properties["津波"] == "◎") | {
    type: "Feature",
    properties: {name: .properties["指定緊急避難場所"], tsunami: true},
    geometry: .geometry
  }]
}' data/raw/shelters-all.geojson > data/shelters-japan.geojson

echo "done: data/shelters-japan.geojson"
ls -lh data/shelters-japan.geojson
