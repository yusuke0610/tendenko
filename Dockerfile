# tendenko データパイプラインの本番実行イメージ (Cloud Run jobs、ADR-0001/0003)。
#
# 開発環境の正本は flake.nix。macOS では tilemaker が動かないため MBTiles 生成は Linux 専用。
# このイメージは Linux コンテナ内で flake からツール (osmium/tilemaker/gdal) を realise し、
# 静的な Go バイナリ (modernc sqlite は cgo 不要) を焼き込む。ビルド自体が Linux なので
# クロスコンパイルや linux-builder は不要 (ADR-0003 の Docker 検証と同じ考え方)。
#
#   docker build -t tendenko-pipeline .
#   docker run --rm -v "$PWD/pipeline/data:/data" tendenko-pipeline \
#     -pbf /data/japan-latest.osm.pbf -out /data/out -tiles \
#     -inundation /data/inundation-japan.geojson -shelters /data/shelters-japan.geojson \
#     -upload gs://<bucket>
FROM nixos/nix:latest

RUN mkdir -p /etc/nix && echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /src
COPY . .

# ランタイムツール (flake.lock 固定) を realise し、静的な Go バイナリをビルドする。
# path:. で非 git の flake として扱い、Docker ビルドコンテキストに .git が無くても動くようにする。
RUN nix build "path:.#pipeline-tools" --out-link /opt/tools \
    && nix develop "path:." --command bash -c \
       "cd pipeline && CGO_ENABLED=0 go build -trimpath -o /usr/local/bin/build-package ./cmd/build-package"

# tilemaker は <bin>/../share/tilemaker の config/process を参照する (buildEnv が share も束ねる)。
ENV PATH="/opt/tools/bin:/usr/local/bin:${PATH}"

ENTRYPOINT ["build-package"]
