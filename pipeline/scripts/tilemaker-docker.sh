#!/bin/sh
# nixpkgs の tilemaker は macOS/arm64 でクラッシュする (ADR-0003)。
# 本番パイプラインは Cloud Run jobs (Linux) で動くため実害はないが、
# ローカル (macOS) で試すときは Docker の Linux コンテナ経由で同じ nixpkgs パッケージを使う。
#
# 使い方:
#   scripts/tilemaker-docker.sh <入力.osm.pbf> <bbox: minLon,minLat,maxLon,maxLat> <出力.mbtiles>
#
# 例:
#   scripts/tilemaker-docker.sh data/mesh-584177.osm.pbf 141.875,39.25,142.0,39.3333333 out/tiles-584177.mbtiles
set -eu

if [ $# -ne 3 ]; then
  echo "usage: $0 <input.osm.pbf> <minLon,minLat,maxLon,maxLat> <output.mbtiles>" >&2
  exit 2
fi

input=$1
bbox=$2
output=$3

cd "$(dirname "$0")/.."
input_abs=$(cd "$(dirname "$input")" && pwd)/$(basename "$input")
mkdir -p "$(dirname "$output")"
output_abs=$(cd "$(dirname "$output")" && pwd)
output_name=$(basename "$output")

docker run --rm \
  -v "$(dirname "$input_abs")":/data:ro \
  -v "$output_abs":/out \
  nixos/nix:latest sh -c "
    nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#tilemaker --command sh -c '
      share=\$(dirname \$(command -v tilemaker))/../share/tilemaker
      tilemaker --input /data/$(basename "$input_abs") --output /out/$output_name \
        --bbox $bbox \
        --config \$share/config-openmaptiles.json --process \$share/process-openmaptiles.lua
    '
  "
echo "done: $output"
