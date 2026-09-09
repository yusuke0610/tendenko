#!/bin/sh
# fetch-tsunami-raster.sh が取得した津波浸水想定のラスタタイルを、
# pipeline/internal/inundation が読む正規化 GeoJSON に変換する
# (ADR-0003 追記 2026-07-29 の設計 3〜6)。
#
# 国土数値情報 A40 に東京都・香川県が含まれないため、ハザードマップポータルサイト
# (国土地理院、PDL1.0) が配信するラスタタイルで補完する。A40 (normalize-a40.sh) や
# 福井県 (normalize-fukui.sh) がベクタ (Shapefile) なのに対し、こちらは PNG タイルなので
# 「色 → 2値マスク → polygonize」の工程が余分に要る。最終フォーマット (県ごとに
# ST_Union で 1 MultiPolygon、simplify 0.00003度 ≈3m、[lon,lat]) は 3 者とも同じ。
#
# ## 浸水域ピクセルの判定
#
# 「アルファが半分以上 かつ 凡例 6 色のいずれかに近い」を浸水域とする。2 条件の
# 併用は、配信タイルが RGBA (背景透過) でも不透明 (背景白) でも同じ判定式で動くようにするため。
#
#   - アルファ: 境界のアンチエイリアス画素は背景と混色して半透明になる。>=128 (半分以上が
#     浸水域で塗られている) を採る。ラスタ由来の輪郭誤差は元々 1 ピクセル (z14 で約 8m) 程度
#   - 色: 凡例 6 色との RGB ユークリッド距離が COLOR_TOL 以内。既定 16 は、凡例色どうしの
#     最小距離 31 (#f285c9 と #dc7adc) の半分以下で、かつ背景白との最小距離 74 (#ffd8c0)
#     から十分離れている。このパイプラインは boolean 判定にしか使わないので、凡例色どうしの
#     取り違えは無害 (背景を拾わないことだけが重要)
#
# 凡例 (6 段階) は国土交通省「水害ハザードマップ作成の手引き」令和5年5月改定に基づく。
# **RGB 値は二次情報由来のため、実タイルとの照合をこのスクリプト自身が行う**:
# 「アルファは不透明なのに 6 色のどれにも一致しない」画素の割合を集計し、閾値
# (UNMATCHED_WARN_PCT、既定 5%) を超えたら警告する。RGB 表が誤っている・凡例が
# 増えた場合はここで気付ける (ADR-0003 の未解決事項「RGB 表の一次情報照合」への対処)。
#
# ## 使い方 (nix develop 内)
#   scripts/fetch-tsunami-raster.sh tokyo && scripts/normalize-raster-tsunami.sh tokyo
#   scripts/fetch-tsunami-raster.sh kagawa && scripts/normalize-raster-tsunami.sh kagawa
#
# 環境変数: COLOR_TOL (既定 16)、ALPHA_MIN (既定 128)、UNMATCHED_WARN_PCT (既定 5)
#
# 出力: data/<name>/<name>.dissolved.geojson (normalize-a40.sh の最終マージが拾う)
set -eu

cd "$(dirname "$0")/.."

name=${1:-}
case "$name" in
  tokyo | kagawa) ;;
  *)
    echo "usage: $0 <tokyo|kagawa>" >&2
    exit 2
    ;;
esac

for tool in gdalbuildvrt gdal_translate gdal_calc.py gdal_polygonize.py ogr2ogr gdalinfo jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool がありません (nix develop 内で実行してください)" >&2; exit 1; }
done

tol=${COLOR_TOL:-16}
alpha_min=${ALPHA_MIN:-128}
warn_pct=${UNMATCHED_WARN_PCT:-5}

dir=data/$name
tiles=$dir/tiles
list=$dir/mosaic-tiles.txt
[ -d "$tiles" ] || { echo "error: $tiles がありません (先に scripts/fetch-tsunami-raster.sh $name を実行してください)" >&2; exit 1; }

work=$dir/.normalize-work
rm -rf "$work"
mkdir -p "$work"

# fetch 側が「中身のあったタイル」だけを列挙してくれている。無ければ全タイルを使う
# (全面透過のタイルはマスクに寄与しないので結果は同じ。VRT が太るだけ)。
if [ -f "$list" ]; then
  sort "$list" > "$work/tiles.txt"
else
  echo "  $list が無いため tiles/ 配下を全件使います"
  find "$tiles" -name '*.png' | sort > "$work/tiles.txt"
fi
ntiles=$(wc -l < "$work/tiles.txt" | tr -d ' ')
[ "$ntiles" -gt 0 ] || { echo "error: $tiles にタイルがありません" >&2; exit 1; }
echo "normalize: $name ($ntiles タイル)"

# --- 1. モザイク化 -----------------------------------------------------------------------
# 配信タイルはパレット PNG のことも RGBA のこともあるため、まず先頭 1 枚で形式を見る。
first=$(head -1 "$work/tiles.txt")
has_ct=$(gdalinfo -json "$first" | jq -r 'if .bands[0].colorTable then "yes" else "no" end')

if [ "$has_ct" = "yes" ]; then
  # **パレット PNG はモザイク化の前に 1 枚ずつ RGBA へ展開する。**
  # gdalbuildvrt は先頭ラスタのカラーテーブルを全タイルに適用してしまい、タイルごとに
  # パレットが違うと (PNG エンコーダは普通タイル単位で最適化するので珍しくない)
  # 警告は出るものの静かに誤った色のモザイクになる — 実際に合成タイルで再現し、
  # 浸水域 0 px という壊れた結果になることを確認した。展開後の VRT は画素をコピーしない
  # ので、タイル数に対して安価。
  echo "  パレット PNG を検出 → タイルごとに RGBA へ展開します"
  mkdir -p "$work/rgba"
  # shellcheck disable=SC2016 # sh -c に渡す式はここで展開させない
  xargs -P 4 -I{} sh -c '
    out="$2/$(printf %s "$1" | tr / _).vrt"
    gdal_translate -q -of VRT -expand rgba "$1" "$out"
  ' _ {} "$PWD/$work/rgba" < "$work/tiles.txt"
  find "$work/rgba" -name '*.vrt' | sort > "$work/mosaic-in.txt"
else
  cp "$work/tiles.txt" "$work/mosaic-in.txt"
fi

# タイル境界でポリゴンが分断されないよう、県内タイルを 1 枚の仮想ラスタに合成してから
# 処理する (タイル単位で polygonize しない)。位置は fetch 側が書いた .wld、SRS はここで与える。
gdalbuildvrt -q -a_srs EPSG:3857 -input_file_list "$work/mosaic-in.txt" "$work/mosaic.vrt"

src=$work/mosaic.vrt
bands=$(gdalinfo -json "$src" | jq -r '.bands | length')
if [ "$bands" -lt 3 ]; then
  echo "error: 想定外の band 構成です (bands=$bands, カラーテーブルなし)" >&2
  echo "  gdalinfo $first で配信タイルの形式を確認してください" >&2
  exit 1
fi
echo "  モザイク: $(gdalinfo -json "$src" | jq -r '"\(.size[0])x\(.size[1]) px, \(.bands|length) bands"')"

# --- 2. 2値化 (色 + アルファ) -------------------------------------------------------------
# 凡例 6 色 (国土交通省「水害ハザードマップ作成の手引き」令和5年5月改定)。
#   1: 〜0.5m #f7f5a9 / 2: 0.5〜3m #ffd8c0 / 3: 3〜5m #ffb7b7
#   4: 5〜10m #ff9191 / 5: 10〜20m #f285c9 / 6: 20m〜 #dc7adc
legend='247,245,169 255,216,192 255,183,183 255,145,145 242,133,201 220,122,220'

# 「6 色との距離の最小値」を numpy 式に組み立てる。uint8 のまま引き算すると
# ラップアラウンドするので 1.0* で float に上げる。距離は二乗のまま比較する (sqrt 不要)。
nearest=
for rgb in $legend; do
  r=${rgb%%,*}
  gb=${rgb#*,}
  g=${gb%%,*}
  b=${gb##*,}
  d="((1.0*A-$r)**2+(1.0*B-$g)**2+(1.0*C-$b)**2)"
  if [ -z "$nearest" ]; then
    nearest=$d
  else
    nearest="minimum($nearest,$d)"
  fi
done
tol2=$((tol * tol))

# gdal_calc.py に渡す band 引数を位置パラメータに積む (アルファの有無で本数が変わるため。
# 引数列を 1 変数に入れて素で展開する書き方は避ける)。$1 (= name) は使い終えている。
set -- -A "$src" --A_band=1 -B "$src" --B_band=2 -C "$src" --C_band=3
if [ "$bands" -ge 4 ]; then
  has_alpha=yes
  opaque="(1.0*D>=$alpha_min)"
  set -- "$@" -D "$src" --D_band=4
  echo "  2値化: アルファ>=$alpha_min かつ 凡例6色との距離<=$tol"
else
  # アルファ band が無い (不透明 RGB) タイル。色の一致だけで判定する。
  has_alpha=no
  opaque="(1.0*A>=0)" # 常に真 (全画素を対象にする)
  echo "  2値化: 凡例6色との距離<=$tol (アルファ band が無いため色のみ)"
fi

gdal_calc.py --quiet --overwrite --type=Byte \
  --co COMPRESS=DEFLATE --co TILED=YES "$@" \
  --calc="logical_and($opaque, $nearest<=$tol2)" \
  --outfile="$work/mask.tif"

# 0/1 ラスタの平均 × 画素数 = 1 の画素数。
count_ones() {
  gdalinfo -json -stats "$1" |
    jq -r '(.bands[0].mean // 0) * (.size[0] | tonumber) * (.size[1] | tonumber) | floor'
}
matched=$(count_ones "$work/mask.tif")
echo "  浸水域 $matched px"
[ "$matched" -gt 0 ] || { echo "error: 浸水域と判定された画素が 0 でした" >&2; exit 1; }

# 自己検査 (RGB 表の一次情報照合の代わり、ADR-0003 の未解決事項):
# 「何かが描かれている (不透明) のに凡例 6 色のどれにも一致しない」画素の割合を見る。
# アルファ band があるときにしか意味がない — 無い場合は「不透明」が背景を含む全画素に
# なってしまい、未一致率がほぼ背景の面積比になるため検査として成立しない。
if [ "$has_alpha" = "yes" ]; then
  gdal_calc.py --quiet --overwrite --type=Byte \
    --co COMPRESS=DEFLATE --co TILED=YES "$@" \
    --calc="logical_and($opaque, $nearest>$tol2)" \
    --outfile="$work/unmatched.tif"
  unmatched=$(count_ones "$work/unmatched.tif")
  pct=$(awk -v u="$unmatched" -v m="$matched" 'BEGIN { printf "%.2f", 100 * u / (u + m) }')
  echo "  不透明だが凡例6色に未一致: $unmatched px ($pct%)"
  over=$(awk -v p="$pct" -v w="$warn_pct" 'BEGIN { print (p > w) ? 1 : 0 }')
  if [ "$over" = "1" ]; then
    # 調査できるよう、未一致マスクだけは作業ディレクトリの掃除から救い出しておく。
    mv "$work/unmatched.tif" "$dir/unmatched.tif"
    echo "warning: 不透明画素の $pct% が凡例 6 色に一致しませんでした (閾値 $warn_pct%)" >&2
    echo "  凡例 RGB 表が実タイルと食い違っている可能性があります。" >&2
    echo "  $dir/unmatched.tif が 1 の箇所の実ピクセル値を確認してください (ADR-0003)。" >&2
  fi
else
  echo "  自己検査はスキップ (アルファ band が無く、不透明画素で絞り込めないため)"
fi

# --- 3. ポリゴン化 -----------------------------------------------------------------------
# -mask に同じラスタを渡すと 0 (非浸水) が除外され、値 1 の領域だけがポリゴンになる。
# -8 (8近傍) は斜めに接する画素を 1 ポリゴンにまとめ、断片数を抑える。
echo "  polygonize..."
gdal_polygonize.py -q -8 "$work/mask.tif" -mask "$work/mask.tif" \
  -f GeoJSON "$work/poly.geojson" poly dn

npoly=$(jq '.features | length' "$work/poly.geojson")
echo "  ポリゴン $npoly 片 (EPSG:3857)"

# --- 4. 再投影 + dissolve + simplify ------------------------------------------------------
# A40・福井と同じ最終フォーマットに揃える。attribution は PDL1.0 の出典表示 +
# 「加工した旨」の明記を兼ねる (build-package が meta.attributions に per-package で記録し、
# アプリの帰属表示に出る。ADR-0002 / docs/licenses.md)。
attribution='ハザードマップポータルサイト (国土地理院) ※タイル画像をポリゴン化'
out=$dir/$name.dissolved.geojson
echo "  dissolve + simplify → $out"
ogr2ogr -f GeoJSON -t_srs EPSG:4326 -makevalid -simplify 0.00003 \
  -lco COORDINATE_PRECISION=6 \
  "$out" "$work/poly.geojson" \
  -dialect sqlite -sql "SELECT ST_Union(geometry) AS geometry, '$attribution' AS attribution FROM poly"

rm -rf "$work" # 中間ラスタは大きいので消す (タイルは data/<name>/tiles に残る)

echo "done: $out"
ls -lh "$out"
