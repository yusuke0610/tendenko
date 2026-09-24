#!/bin/sh
# fetch-tsunami-raster.sh が取得した津波浸水想定のラスタタイルを、
# pipeline/internal/inundation が読む正規化 GeoJSON に変換する
# (ADR-0003 追記 2026-07-29 の設計 3〜6)。
#
# 国土数値情報 A40 に東京都・香川県が含まれないため、ハザードマップポータルサイト
# (国土地理院、PDL1.0) が配信するラスタタイルで補完する。A40 (normalize-a40.sh) や
# 福井県 (normalize-fukui.sh) がベクタ (Shapefile) なのに対し、こちらは PNG タイルなので
# 「色 → 2値マスク → polygonize」の工程が余分に要る。最終フォーマット (県ごとに
# ST_Union で 1 MultiPolygon、simplify ≈3m、[lon,lat]) は 3 者とも同じ。
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

for tool in gdalbuildvrt gdal_translate gdal_calc.py gdal_polygonize.py ogr2ogr ogrinfo gdalinfo jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool がありません (nix develop 内で実行してください)" >&2; exit 1; }
done

tol=${COLOR_TOL:-16}
alpha_min=${ALPHA_MIN:-128}
warn_pct=${UNMATCHED_WARN_PCT:-5}

dir=data/$name
tiles=$dir/tiles
list=$dir/mosaic-tiles.txt
# mosaic-tiles.txt は fetch が最後まで完了したときにだけ書かれる。無ければ fetch が
# 途中で止まっており、tiles/ には中間 zoom のタイルや取得途中の最終 zoom が混在しうる
# (解像度の違うタイルが混ざる・浸水域が欠ける) ので、tiles/ 全件での代替はせずに止める。
[ -f "$list" ] || { echo "error: $list がありません (fetch が完了していません。scripts/fetch-tsunami-raster.sh $name を再実行してください)" >&2; exit 1; }

work=$dir/.normalize-work
rm -rf "$work"
mkdir -p "$work"

# fetch 側が「中身のあったタイル」だけを列挙してくれている。
sort "$list" > "$work/tiles.txt"
ntiles=$(wc -l < "$work/tiles.txt" | tr -d ' ')
[ "$ntiles" -gt 0 ] || { echo "error: $tiles にタイルがありません" >&2; exit 1; }
echo "normalize: $name ($ntiles タイル)"

# --- 1. 形式の判定 -----------------------------------------------------------------------
# 配信タイルはパレット PNG のことも RGBA のこともあり、**形式はタイルごとに判定する**
# (PNG エンコーダはタイル単位で最適化するので、同じ県の中で形式が混在しうる)。
#
# **パレット PNG はモザイク化の前に 1 枚ずつ RGBA へ展開する。**
# gdalbuildvrt は先頭ラスタのカラーテーブルを全タイルに適用してしまい、タイルごとに
# パレットが違うと警告は出るものの静かに誤った色のモザイクになる — 実際に合成タイルで
# 再現し、浸水域 0 px という壊れた結果になることを確認した。展開後の VRT は画素を
# コピーしないので、タイル数に対して安価。
#
# 展開後も band 数が揃わない (不透明 RGB と RGBA の混在など) と、gdalbuildvrt は
# 合わない入力を警告付きで読み飛ばし、その浸水域が静かに消える。よって揃わなければ止める。
# 各行 "<band数> <元タイルのパス> <モザイク入力パス>"。読めない・展開に失敗したタイルは
# 行を出さない (下で候補数と行数を突き合わせて検出する)。
mkdir -p "$work/rgba"
# shellcheck disable=SC2016 # sh -c に渡す式はここで展開させない
xargs -P 4 -I{} sh -c '
  if gdalinfo -json "$1" | jq -e ".bands[0].colorTable" >/dev/null; then
    out="$2/$(printf %s "$1" | tr / _).vrt"
    gdal_translate -q -of VRT -expand rgba "$1" "$out" && echo "4 $1 $out"
  else
    # gdalinfo が失敗すると jq は空入力で 0 を返すため、数値であることまで確かめる。
    n=$(gdalinfo -json "$1" | jq ".bands | length")
    case "$n" in "" | *[!0-9]*) exit 0 ;; esac
    echo "$n $1 $1"
  fi
' _ {} "$PWD/$work/rgba" < "$work/tiles.txt" > "$work/classified.raw" || true
nclassified=$(wc -l < "$work/classified.raw" | tr -d ' ')
if [ "$nclassified" -ne "$ntiles" ]; then
  echo "error: $ntiles タイル中 $nclassified タイルしか形式を判定できませんでした" >&2
  echo "  読めないタイルを消して scripts/fetch-tsunami-raster.sh $name を再実行してください" >&2
  exit 1
fi
nexpanded=$(grep -c '\.vrt$' "$work/classified.raw" || true)
if [ "$nexpanded" -gt 0 ]; then
  echo "  パレット PNG $nexpanded タイルを RGBA へ展開しました"
fi
kinds=$(cut -d' ' -f1 "$work/classified.raw" | sort -u | wc -l | tr -d ' ')
if [ "$kinds" -ne 1 ]; then
  echo "error: band 構成の異なるタイルが混在しています (パレット展開後の band 数: 枚数)" >&2
  cut -d' ' -f1 "$work/classified.raw" | sort | uniq -c | sed 's/^/  /' >&2
  exit 1
fi
first=$(head -1 "$work/tiles.txt")
bands=$(head -1 "$work/classified.raw" | cut -d' ' -f1)
if [ "$bands" -lt 3 ]; then
  echo "error: 想定外の band 構成です (bands=$bands, カラーテーブルなし)" >&2
  echo "  gdalinfo $first で配信タイルの形式を確認してください" >&2
  exit 1
fi

# --- 2. 連結したタイル群への分割 ----------------------------------------------------------
# タイル境界でポリゴンが分断されないよう、隣接するタイルは 1 枚の仮想ラスタに合成してから
# 処理する (タイル単位で polygonize しない)。ただし**県全体を 1 枚にはしない**: 東京都は
# 伊豆諸島・小笠原諸島・南鳥島と島しょが数百〜千 km 離れて散らばっており、全タイルの外接矩形は
# z14 で数十億画素になる。後段の 2 値化・統計・polygonize は外接矩形の全画素を舐めるので、
# 処理時間とディスクが浸水域ではなく「島どうしの間の海」の広さで決まってしまう。
#
# そこでタイルを 8 近傍 (斜め含む) の連結成分に分け、成分ごとにモザイク → 2 値化 →
# polygonize する。浸水域ポリゴンが複数タイルにまたがるなら、それらのタイルは互いに隣接
# しているので必ず同じ成分に入る — 成分をまたいで分断されるポリゴンは生じない
# (隣接しない成分どうしの間には中身の無いタイルしか無い)。最後に ST_Union で 1 つに統合する。
#
# 連結成分は union-find で求める。入力のタイルパスは .../tiles/<z>/<x>/<y>.png。
awk '
  function find(i) { while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i] } return i }
  function unite(a, b) { a = find(a); b = find(b); if (a != b) parent[a] = b }
  {
    n = split($2, p, "/")
    x = p[n - 1]; y = p[n]; sub(/\.png$/, "", y)
    X[NR] = x; Y[NR] = y; parent[NR] = NR; input[NR] = $3
    at[x "," y] = NR
  }
  END {
    for (i = 1; i <= NR; i++)
      for (dx = -1; dx <= 1; dx++)
        for (dy = -1; dy <= 1; dy++)
          if ((X[i] + dx) "," (Y[i] + dy) in at) unite(i, at[(X[i] + dx) "," (Y[i] + dy)])
    for (i = 1; i <= NR; i++) print find(i), input[i]
  }' "$work/classified.raw" | sort -k1,1n -k2 > "$work/grouped.txt"

mkdir -p "$work/groups"
awk -v d="$work/groups" '{ print $2 > (d "/" $1 ".txt") }' "$work/grouped.txt"
ngroups=$(find "$work/groups" -name '*.txt' | wc -l | tr -d ' ')
echo "  連結したタイル群: $ngroups 個"

# --- 3. 2値化 (色 + アルファ) -------------------------------------------------------------
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

if [ "$bands" -ge 4 ]; then
  has_alpha=yes
  opaque="(1.0*D>=$alpha_min)"
  echo "  2値化: アルファ>=$alpha_min かつ 凡例6色との距離<=$tol"
else
  # アルファ band が無い (不透明 RGB) タイル。色の一致だけで判定する。
  has_alpha=no
  opaque="(1.0*A>=0)" # 常に真 (全画素を対象にする)
  echo "  2値化: 凡例6色との距離<=$tol (アルファ band が無いため色のみ)"
fi

# calc <モザイク> <式> <出力>。gdal_calc.py の band 引数はアルファの有無で本数が変わるので
# 位置パラメータに積む (引数列を 1 変数に入れて素で展開する書き方は避ける。関数内の
# set -- は呼び出し側の位置パラメータを壊さない)。
calc() {
  src=$1
  expr=$2
  outfile=$3
  set -- -A "$src" --A_band=1 -B "$src" --B_band=2 -C "$src" --C_band=3
  if [ "$has_alpha" = "yes" ]; then
    set -- "$@" -D "$src" --D_band=4
  fi
  gdal_calc.py --quiet --overwrite --type=Byte \
    --co COMPRESS=DEFLATE --co TILED=YES "$@" \
    --calc="$expr" --outfile="$outfile"
}

# 0/1 ラスタの平均 × 画素数 = 1 の画素数。
count_ones() {
  gdalinfo -json -stats "$1" |
    jq -r '(.bands[0].mean // 0) * (.size[0] | tonumber) * (.size[1] | tonumber) | floor'
}

# --- 4. タイル群ごとに モザイク → 2値化 → ポリゴン化 ----------------------------------------
# -mask に同じラスタを渡すと 0 (非浸水) が除外され、値 1 の領域だけがポリゴンになる。
# -8 (8近傍) は斜めに接する画素を 1 ポリゴンにまとめ、断片数を抑える。
# 各群のポリゴンは 1 つの GeoPackage レイヤ (poly) に追記し、最後にまとめて ST_Union する。
echo "  モザイク → 2値化 → polygonize (タイル群ごと)..."
matched=0
unmatched=0
area=0
mkdir -p "$work/unmatched"
for list_g in "$work"/groups/*.txt; do
  g=$(basename "$list_g" .txt)
  vrt=$work/groups/$g.vrt
  # 位置は fetch 側が書いた .wld、SRS はここで与える。
  gdalbuildvrt -q -a_srs EPSG:3857 -input_file_list "$list_g" "$vrt"
  px=$(gdalinfo -json "$vrt" | jq -r '.size[0] * .size[1]')
  area=$((area + px))

  calc "$vrt" "logical_and($opaque, $nearest<=$tol2)" "$work/groups/$g.mask.tif"
  m=$(count_ones "$work/groups/$g.mask.tif")
  matched=$((matched + m))

  if [ "$has_alpha" = "yes" ]; then
    calc "$vrt" "logical_and($opaque, $nearest>$tol2)" "$work/unmatched/$g.tif"
    u=$(count_ones "$work/unmatched/$g.tif")
    unmatched=$((unmatched + u))
    # 未一致が無い群のマスクは調査に要らないので残さない。
    [ "$u" -gt 0 ] || rm -f "$work/unmatched/$g.tif"
  fi

  if [ "$m" -gt 0 ]; then
    gdal_polygonize.py -q -8 "$work/groups/$g.mask.tif" -mask "$work/groups/$g.mask.tif" \
      -f GeoJSON "$work/groups/$g.poly.geojson" poly dn
    # 後段の ST_Union(geometry) に合わせ、GeoPackage の既定 (geom) ではなく geometry にする。
    ogr2ogr -f GPKG -append -nln poly -lco GEOMETRY_NAME=geometry \
      "$work/poly.gpkg" "$work/groups/$g.poly.geojson"
  fi
  # 中間ラスタは群ごとに消し、ディスク使用量を最大の 1 群ぶんに抑える。
  rm -f "$work/groups/$g.mask.tif" "$work/groups/$g.poly.geojson"
done
echo "  処理した画素 $area px (タイル群の外接矩形の合計)"
echo "  浸水域 $matched px"
[ "$matched" -gt 0 ] || { echo "error: 浸水域と判定された画素が 0 でした" >&2; exit 1; }

# 自己検査 (RGB 表の一次情報照合の代わり、ADR-0003 の未解決事項):
# 「何かが描かれている (不透明) のに凡例 6 色のどれにも一致しない」画素の割合を見る。
# アルファ band があるときにしか意味がない — 無い場合は「不透明」が背景を含む全画素に
# なってしまい、未一致率がほぼ背景の面積比になるため検査として成立しない。
rm -rf "$dir/unmatched"
if [ "$has_alpha" = "yes" ]; then
  pct=$(awk -v u="$unmatched" -v m="$matched" 'BEGIN { printf "%.2f", 100 * u / (u + m) }')
  echo "  不透明だが凡例6色に未一致: $unmatched px ($pct%)"
  over=$(awk -v p="$pct" -v w="$warn_pct" 'BEGIN { print (p > w) ? 1 : 0 }')
  if [ "$over" = "1" ]; then
    # 調査できるよう、未一致マスク (未一致のあった群のみ) は作業ディレクトリの掃除から救い出す。
    mv "$work/unmatched" "$dir/unmatched"
    echo "warning: 不透明画素の $pct% が凡例 6 色に一致しませんでした (閾値 $warn_pct%)" >&2
    echo "  凡例 RGB 表が実タイルと食い違っている可能性があります。" >&2
    echo "  $dir/unmatched/*.tif が 1 の箇所の実ピクセル値を確認してください (ADR-0003)。" >&2
  fi
else
  echo "  自己検査はスキップ (アルファ band が無く、不透明画素で絞り込めないため)"
fi

npoly=$(ogrinfo -q -sql 'SELECT COUNT(*) AS n FROM poly' "$work/poly.gpkg" | awk '/n \(Integer/ { print $NF }')
echo "  ポリゴン $npoly 片 (EPSG:3857)"

# --- 5. 再投影 + dissolve + simplify ------------------------------------------------------
# A40・福井と同じ最終フォーマットに揃える。attribution は PDL1.0 の出典表示 +
# 「加工した旨」の明記を兼ねる (build-package が meta.attributions に per-package で記録し、
# アプリの帰属表示に出る。ADR-0002 / docs/licenses.md)。
attribution='ハザードマップポータルサイト (国土地理院) ※タイル画像をポリゴン化'
out=$dir/$name.dissolved.geojson
echo "  dissolve + simplify → $out"
# -simplify は再投影 (-t_srs) の前に入力 SRS の単位で効く。poly.gpkg は EPSG:3857 (m) なので、
# A40・福井の 0.00003度 (≈3m) に揃えるには地上 3m 相当をメルカトルの m で与える。
# メルカトルの縮尺は 1/cos(緯度) 倍で、北緯34度付近で 3m × 1.21 ≈ 3.6。
ogr2ogr -f GeoJSON -t_srs EPSG:4326 -makevalid -simplify 3.6 \
  -lco COORDINATE_PRECISION=6 \
  "$out" "$work/poly.gpkg" \
  -dialect sqlite -sql "SELECT ST_Union(geometry) AS geometry, '$attribution' AS attribution FROM poly"

rm -rf "$work" # 中間ラスタは大きいので消す (タイルは data/<name>/tiles に残る)

echo "done: $out"
ls -lh "$out"
