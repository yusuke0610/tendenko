#!/bin/sh
# ハザードマップポータルサイト (国土地理院) が配信する津波浸水想定のラスタタイルを取得する
# (ADR-0003 追記 2026-07-29 の設計 1〜2)。国土数値情報 A40 に含まれない東京都・香川県を、
# ラスタ → ポリゴン変換で補完するための前段。取得したタイルは normalize-raster-tsunami.sh が
# モザイク化 → 2値化 → polygonize する。
#
# 配信元 (ADR-0003 追記 2026-07-28 で実タイルの取得を確認済み、PDL1.0):
#   https://disaportaldata.gsi.go.jp/raster/04_tsunami_newlegend_pref_data/<都道府県コード>/{z}/{x}/{y}.png
#
# ## なぜ bbox の全列挙ではなくピラミッド降下なのか
#
# 東京都の bbox は沖ノ鳥島 (東経 136.08) から南鳥島 (東経 153.98) までの約 18 度四方に
# なり、z14 で素直に列挙すると 50 万枚を超える。実際にデータがあるのは島しょ部と湾岸の
# ごく一部だけなので、粗い zoom から始めて「データがあったタイルの子だけ」を辿る
# (ピラミッド降下)。取得枚数が実カバレッジに比例するようになり、同時に
# 「どこにデータがあるのか」(ADR-0003 の未解決事項: 東京都本土部のカバレッジ) が
# coverage.txt として副産物で得られる。
#
# ## 使い方 (nix develop 内)
#   scripts/fetch-tsunami-raster.sh tokyo
#   scripts/fetch-tsunami-raster.sh kagawa
#
# 環境変数:
#   ZOOM        取得する最終 zoom (既定 14)。7.9m/px @ 北緯34度 で、元の浸水想定モデルの
#               10m メッシュ (A40・福井と同じ) 相当。上げても元データ以上の精度は出ない
#   START_ZOOM  ピラミッドの開始 zoom (既定 8)。この zoom で 1 枚も取れなければ自動的に
#               +2 して再試行する (z10/z12 は ADR-0003 追記 2026-07-28 で実タイル取得確認済み)
#   JOBS        並列取得数 (既定 4)。配信元に配慮して控えめにしている
#
# 出力:
#   data/<name>/tiles/<z>/<x>/<y>.png  最終 zoom のタイル (+ .wld ワールドファイル)
#   data/<name>/mosaic-tiles.txt       うち中身のあるタイルのパス (normalize が読む)
#   data/<name>/coverage.txt           zoom ごとの 200/404/空タイル数のレポート
#
# 既に存在するタイルは再取得しない (中断しても再実行で続きから)。
set -eu

# --- ワーカーモード (xargs から自身を呼び出す。sh では関数を export できないため) ----------
# 1 タイルを取得し、成否と中身の有無を stdout に 1 行で報告する。
#   HIT <z> <x> <y>    200 かつ内容あり (次の zoom はこのタイルの子を辿る)
#   EMPTY <z> <x> <y>  200 だが全ピクセル透過 (浸水域なし。子は辿らない)
#   MISS <z> <x> <y>   404 (配信対象外セル。子は辿らない)
#   FAIL <z> <x> <y>   通信エラー・想定外のステータス。**「データなし」と区別する** —
#                      一時的な失敗を黙って「浸水域なし」に倒すと、浸水想定が欠けた
#                      パッケージが静かに出来上がる。呼び出し側で必ず失敗させる
if [ "${1:-}" = "--fetch-one" ]; then
  z=$2
  x=$3
  y=$4
  png="$FTR_TILEDIR/$z/$x/$y.png"

  if [ ! -f "$png" ]; then
    mkdir -p "$(dirname "$png")"
    tmp="$png.part"
    # --retry-all-errors は転送途中の切断もリトライ対象にする (--retry 単体では
    # タイムアウトと 5xx にしか効かない)。404 は curl 的には成功なのでリトライされない。
    # set -e 下では代入の失敗でそのまま抜けてしまうので、|| で終了コードを受け取る。
    curl_status=0
    code=$(curl -sS --retry 3 --retry-delay 2 --retry-all-errors --max-time 60 \
      -o "$tmp" -w '%{http_code}' \
      "$FTR_BASE_URL/$FTR_PREF/$z/$x/$y.png" 2>/dev/null) || curl_status=$?
    if [ "$curl_status" -ne 0 ]; then
      rm -f "$tmp"
      echo "FAIL $z $x $y"
      exit 0
    fi
    if [ "$code" = "404" ]; then
      rm -f "$tmp"
      echo "MISS $z $x $y"
      exit 0
    fi
    if [ "$code" != "200" ]; then
      rm -f "$tmp"
      echo "FAIL $z $x $y"
      exit 0
    fi
    mv "$tmp" "$png"
  fi

  # 全ピクセルが透過なら「浸水域なし」。RGBA (アルファ band あり) のときだけ判定でき、
  # パレット PNG 等では判定できないため保守的に HIT 扱いにする (モザイクが少し太るだけで
  # マスクの正しさには影響しない)。GDAL_PAM_ENABLED=NO で .aux.xml を作らせない。
  # jq 側で真偽まで畳んで 0/1 を返させる (computedMax は 0.0 のような浮動小数で来るため、
  # シェルの文字列比較で 0 判定してはいけない)。
  empty=$(GDAL_PAM_ENABLED=NO gdalinfo -json -mm "$png" 2>/dev/null |
    jq -r '.bands
           | if length >= 4 and .[3].colorInterpretation == "Alpha"
             then (if (.[3].computedMax // 1) == 0 then 1 else 0 end)
             else 0 end' 2>/dev/null) || empty=0
  if [ "$empty" = "1" ]; then
    echo "EMPTY $z $x $y"
    exit 0
  fi

  # XYZ タイルの位置を GDAL に伝えるワールドファイル (.wld) を書く。SRS は
  # gdalbuildvrt -a_srs EPSG:3857 で与えるため .prj は要らない。
  # Web メルカトルの全球幅 = 2 * 20037508.342789244 m。
  awk -v z="$z" -v x="$x" -v y="$y" 'BEGIN {
    half = 20037508.342789244
    span = 2 * half / (2 ^ z)   # 1 タイルの一辺 (m)
    px   = span / 256           # 1 ピクセルの一辺 (m)
    ulx  = -half + x * span
    uly  =  half - y * span
    # ワールドファイルの 5,6 行目は「左上ピクセルの中心」座標。
    printf "%.12f\n0.0\n0.0\n%.12f\n%.12f\n%.12f\n", px, -px, ulx + px / 2, uly - px / 2
  }' > "${png%.png}.wld"

  echo "HIT $z $x $y"
  exit 0
fi

# --- 本体 -------------------------------------------------------------------------------
cd "$(dirname "$0")/.."

name=${1:-}
case "$name" in
  # name          都道府県コード  bbox (minlon minlat maxlon maxlat)
  # 東京都: 沖ノ鳥島 (136.08E, 20.42N) 〜 南鳥島 (153.98E) 〜 本土北端 (35.90N) を包む。
  #         広いが、実際に取得するのはピラミッド降下でデータが見つかった枝だけ。
  tokyo)  pref=13; bbox="136.00 20.40 154.05 35.92" ;;
  # 香川県: 伊吹島 (133.49E) 〜 小豆島東端 (134.45E)、南は県境、北は小豆島北端。
  kagawa) pref=37; bbox="133.40 33.95 134.50 34.60" ;;
  *)
    echo "usage: $0 <tokyo|kagawa>" >&2
    exit 2
    ;;
esac

for tool in curl jq gdalinfo awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool がありません (nix develop 内で実行してください)" >&2; exit 1; }
done

zoom=${ZOOM:-14}
start_zoom=${START_ZOOM:-8}
jobs=${JOBS:-4}
if [ "$start_zoom" -gt "$zoom" ]; then
  echo "error: START_ZOOM ($start_zoom) が ZOOM ($zoom) を超えています" >&2
  exit 2
fi

# BASE_URL は配信元 (通常は上書き不要)。テストで合成タイルサーバに向けるために外に出している。
FTR_BASE_URL=${BASE_URL:-https://disaportaldata.gsi.go.jp/raster/04_tsunami_newlegend_pref_data}
FTR_PREF=$pref
FTR_TILEDIR="$PWD/data/$name/tiles"
export FTR_BASE_URL FTR_PREF FTR_TILEDIR

work=data/$name/.fetch-work
rm -rf "$work"
mkdir -p "$work" "$FTR_TILEDIR"
coverage=data/$name/coverage.txt
dirlist=data/$name/mosaic-tiles.txt

# bbox を指定 zoom の XYZ タイル座標へ (標準の slippy map 式)。
# x = (lon+180)/360 * 2^z, y = (1 - ln(tan φ + sec φ)/π)/2 * 2^z
enumerate_bbox() {
  echo "$bbox" | awk -v z="$1" '{
    pi = atan2(0, -1)
    n  = 2 ^ z
    xmin = int(($1 + 180) / 360 * n)
    xmax = int(($3 + 180) / 360 * n)
    # 緯度は北ほど y が小さいので maxlat から ymin を出す。
    for (i = 0; i < 2; i++) {
      lat = (i == 0 ? $4 : $2) * pi / 180
      yy  = int((1 - log(sin(lat) / cos(lat) + 1 / cos(lat)) / pi) / 2 * n)
      if (i == 0) ymin = yy; else ymax = yy
    }
    if (xmin < 0) xmin = 0
    if (ymin < 0) ymin = 0
    if (xmax > n - 1) xmax = n - 1
    if (ymax > n - 1) ymax = n - 1
    for (x = xmin; x <= xmax; x++)
      for (y = ymin; y <= ymax; y++)
        print z, x, y
  }'
}

echo "fetch: $name (都道府県コード $pref) z$start_zoom → z$zoom, 並列 $jobs"
echo "# fetch-tsunami-raster.sh $name (都道府県コード $pref)" > "$coverage"
echo "# 生成: $(date -u '+%Y-%m-%dT%H:%M:%SZ')  bbox: $bbox  最終zoom: $zoom" >> "$coverage"
echo "# zoom 候補 HIT EMPTY MISS(404)" >> "$coverage"

# 通信エラーは「データなし」に倒さず、必ず失敗させる (浸水想定が欠けたまま
# パッケージが出来上がるのを防ぐ)。取得済みタイルはキャッシュされるので再実行は安い。
abort_on_fail() {
  fails=$(grep -c '^FAIL ' "$work/res" || true)
  [ "$fails" -eq 0 ] && return 0
  echo "error: $fails 枚のタイルで通信エラー・想定外のステータスが発生しました (z$1)" >&2
  grep '^FAIL ' "$work/res" | head -5 | sed 's/^/  /' >&2
  echo "  「配信対象外 (404)」と区別できないため中断します。" >&2
  echo "  取得済みのタイルはキャッシュされているので、そのまま再実行してください。" >&2
  exit 1
}

# 開始 zoom で 1 枚も取れなければ +2 して再試行する。配信元の最小 zoom を仮定しないため。
z=$start_zoom
while :; do
  enumerate_bbox "$z" > "$work/cand"
  n=$(wc -l < "$work/cand" | tr -d ' ')
  echo "  z$z: 候補 $n 枚を探索..."
  xargs -P "$jobs" -n 3 "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" --fetch-one \
    < "$work/cand" > "$work/res" 2>/dev/null || true
  abort_on_fail "$z"
  hits=$(grep -c '^HIT ' "$work/res" || true)
  if [ "$hits" -gt 0 ]; then
    break
  fi
  if [ "$z" -ge "$zoom" ]; then
    echo "error: z$start_zoom〜z$zoom のどこでもタイルを取得できませんでした" >&2
    echo "  配信元の URL / 都道府県コード / bbox を確認してください" >&2
    exit 1
  fi
  z=$((z + 2))
  [ "$z" -gt "$zoom" ] && z=$zoom
  echo "  → 0 枚。開始 zoom を z$z に上げて再試行します"
done

# ここから降下: 「HIT だったタイル」の子 4 枚だけを次の zoom の候補にする。
while :; do
  empties=$(grep -c '^EMPTY ' "$work/res" || true)
  misses=$(grep -c '^MISS ' "$work/res" || true)
  cands=$(wc -l < "$work/cand" | tr -d ' ')
  printf 'z%-3s %8s %8s %8s %8s\n' "$z" "$cands" "$hits" "$empties" "$misses" >> "$coverage"
  echo "  z$z: HIT $hits / EMPTY $empties / MISS $misses (候補 $cands)"

  [ "$z" -ge "$zoom" ] && break

  grep '^HIT ' "$work/res" | awk '{
    z = $2 + 1
    for (dx = 0; dx < 2; dx++)
      for (dy = 0; dy < 2; dy++)
        print z, $3 * 2 + dx, $4 * 2 + dy
  }' > "$work/cand"
  z=$((z + 1))
  n=$(wc -l < "$work/cand" | tr -d ' ')
  echo "  z$z: 候補 $n 枚を取得..."
  xargs -P "$jobs" -n 3 "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" --fetch-one \
    < "$work/cand" > "$work/res" 2>/dev/null || true
  abort_on_fail "$z"
  hits=$(grep -c '^HIT ' "$work/res" || true)
done

# 最終 zoom で中身のあったタイルだけをモザイクの入力リストにする。全面透過のタイルは
# マスクに寄与しないので混ぜても結果は同じだが、VRT と読み込みが無駄に太る。
# (ファイル自体は残す — 再実行時の再取得を避けるキャッシュとして効く)
grep '^HIT ' "$work/res" | awk -v d="$FTR_TILEDIR" '{ print d "/" $2 "/" $3 "/" $4 ".png" }' \
  > "$dirlist"

# 中間 zoom のタイルは降下の探索用でしかない。モザイクに混ざると解像度が食い違うため消す。
find "$FTR_TILEDIR" -mindepth 1 -maxdepth 1 -type d ! -name "$zoom" -exec rm -rf {} +
rm -rf "$work"

kept=$(wc -l < "$dirlist" | tr -d ' ')
echo "done: 中身のあるタイル $kept 枚 (z$zoom) → $dirlist"
echo "カバレッジ: $coverage"
cat "$coverage"
