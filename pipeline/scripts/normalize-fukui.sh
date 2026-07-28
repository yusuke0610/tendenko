#!/bin/sh
# 福井県の津波浸水想定 Shapefile を、pipeline/internal/inundation が読む正規化 GeoJSON に
# 変換する (ADR-0003 追記 2026-07-25)。国土数値情報 A40 に福井県は含まれないため、県が
# CC BY 4.0 で公開する独自データで補完する。
#
# A40 (normalize-a40.sh) との違い:
#   - .prj が同梱されず SRS 不明。座標はメートル単位の平面直角座標系第6系 (福井県)。
#     JGD2011 = EPSG:6674 を明示指定する (サンプル座標を WGS84 変換して福井県沿岸に
#     着地することを確認済み)
#   - zip 内のディレクトリ名が Shift-JIS で、unzip がエンコーディングを解釈できず
#     ディレクトリ作成に失敗する。unzip -j (junk paths) で階層を落として回避する
#   - 10m メッシュの浸水深ポリゴン (72,806 件) を、A40 と同様に ST_Union で 1 つの
#     MultiPolygon に統合し simplify 0.00003度 (≈3m) で単純化する。boolean 判定にしか
#     使わないため浸水深属性は捨てる
#
# 取得元 (公式ページで実 URL を確認、CC BY 4.0):
#   https://www.pref.fukui.lg.jp/doc/dx-suishin/opendata/list_1.html
#   → https://www.pref.fukui.lg.jp/doc/dx-suishin/opendata/list_1_d/fil/tsunamishinsuisouteizu.zip
#
# 使い方 (nix develop 内):
#   1. data/fukui/tsunamishinsuisouteizu.zip を上記 URL から取得しておく
#   2. scripts/normalize-fukui.sh
#
# 出力: data/fukui/fukui.dissolved.geojson (normalize-a40.sh の最終マージが拾う)
set -eu

cd "$(dirname "$0")/.."
zip=data/fukui/tsunamishinsuisouteizu.zip
if [ ! -f "$zip" ]; then
  echo "error: $zip がありません (ADR-0003 の URL から取得してください)" >&2
  exit 1
fi

dir=data/fukui/extract
rm -rf "$dir"
mkdir -p "$dir"
# Shift-JIS ディレクトリ名を回避するため -j で階層を落として展開する。
unzip -j -o -q "$zip" -d "$dir"
shp=$(find "$dir" -name '*.shp' | head -1)
layer=$(basename "$shp" .shp)
echo "normalize: fukui ($layer)"

# .prj が無いので -s_srs で第6系 (EPSG:6674) を明示する。
ogr2ogr -f GeoJSON -s_srs EPSG:6674 -t_srs EPSG:4326 -makevalid -simplify 0.00003 \
  -lco COORDINATE_PRECISION=6 \
  data/fukui/fukui.dissolved.geojson "$shp" \
  -dialect sqlite -sql "SELECT ST_Union(geometry) AS geometry FROM \"$layer\""

rm -rf "$dir" # 展開済み shp は変換後不要 (ディスク節約)

echo "done: data/fukui/fukui.dissolved.geojson"
ls -lh data/fukui/fukui.dissolved.geojson
