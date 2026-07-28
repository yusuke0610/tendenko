#!/bin/sh
# 国土数値情報 A40 (津波浸水想定データ) の都道府県別 Shapefile を、
# pipeline/internal/inundation が読む正規化 GeoJSON に変換する (ADR-0003)。
#
# 各都道府県の shp は数万件の depth-band ポリゴンに分かれているが、このパイプラインは
# 「エッジが浸水想定区域に触れるか」の boolean 判定にしか使わないため、県ごとに
# ST_Union で 1 つの MultiPolygon に統合してからマージする。これによりファイルサイズが
# 1 桁小さくなり (実測: 青森県 56MB → 7.3MB)、inundation.Index の構築も速くなる。
# -simplify 0.00003度 (≈3m) は、エッジを両端点+中点でサンプルする既存の近似判定
# (inundation.go) の誤差予算に対して無視できる精度低下。
#
# 使い方:
#   1. データ入手元 URL のリストを data/raw/a40_urls.txt に用意する (ADR-0003 参照)
#   2. xargs -P 4 -I{} curl -sL -O {} < data/raw/a40_urls.txt  (data/a40/ で実行)
#   3. nix develop 内で: scripts/normalize-a40.sh
#
# 出力: data/inundation-japan.geojson (44 都道府県分の MultiPolygon を結合した FeatureCollection)
set -eu

cd "$(dirname "$0")/.."
mkdir -p data/a40/extract
rm -f data/a40/*.dissolved.geojson

for zip in data/a40/*.zip; do
  base=$(basename "$zip" .zip)
  dir="data/a40/extract/$base"
  mkdir -p "$dir"
  # 一部の zip は Shift-JIS ファイル名の付属 txt (ソフトウェアについて等) を含み、
  # unzip がエンコーディングを解釈できず書き込みエラーになることがある (shp 側には無関係)。
  unzip -o -q "$zip" -x '*.txt' -d "$dir"
  shp=$(find "$dir" -name '*.shp' | head -1)
  layer=$(basename "$shp" .shp)
  echo "normalize: $base ($layer)"
  ogr2ogr -f GeoJSON -t_srs EPSG:4326 -makevalid -simplify 0.00003 \
    -lco COORDINATE_PRECISION=6 \
    "data/a40/$base.dissolved.geojson" "$shp" \
    -dialect sqlite -sql "SELECT ST_Union(geometry) AS geometry FROM \"$layer\""
  rm -rf "$dir" # 展開済み shp は変換後不要 (ディスク節約)
done

# A40 (44 都道府県) に、A40 欠落県の独自データ (normalize-fukui.sh の出力) があれば加える。
# 福井県は CC BY 4.0 の独自津波浸水想定を補完する (ADR-0003 追記 2026-07-25)。
jq -s '{type: "FeatureCollection", features: [.[].features[]]}' \
  data/a40/*.dissolved.geojson \
  $(ls data/fukui/fukui.dissolved.geojson 2>/dev/null) \
  > data/inundation-japan.geojson

echo "done: data/inundation-japan.geojson"
ls -lh data/inundation-japan.geojson
