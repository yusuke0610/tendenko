{
  description = "tendenko — 津波避難アプリの開発環境 (正本)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        # パイプラインの本番実行 (Cloud Run jobs) 用のツール束 (ADR-0001/0003)。
        # Dockerfile が Linux コンテナ内で `nix build .#pipeline-tools` して realise する。
        # flake.lock 固定なので devShell と同一バージョンの osmium/tilemaker/gdal になる。
        packages.pipeline-tools = pkgs.buildEnv {
          name = "tendenko-pipeline-tools";
          paths = with pkgs; [
            osmium-tool
            tilemaker
            gdal
            bashInteractive
            coreutils
          ];
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # iOS (Xcode 本体は Nix 管理外。プロジェクト生成のみ Nix 提供)
            xcodegen

            # Go (server/, pipeline/)
            go # 1.23+
            gopls
            golangci-lint

            # インフラ
            opentofu

            # 地理データパイプライン
            gdal
            osmium-tool
            tilemaker

            # ユーティリティ
            sqlite
            jq
            git-cliff
            nixfmt
          ];

          # Swift/Xcode は Nix で管理しない (macOS の Xcode 前提)。
          # nix develop は PATH を置き換えるため、Xcode の swift/xcodebuild (/usr/bin) を
          # 後ろに追加して見えるようにする。存在しなければ警告のみ。
          # Makefile が全レシピをこのシェル経由で実行するため、正常時は無音にしておく。
          shellHook = ''
            export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
            # nix の apple-sdk が DEVELOPER_DIR/SDKROOT を nix 側に向けるため、
            # /usr/bin/swift や xcodebuild が壊れる。実際の Xcode に戻す。
            # xcode-select -p は DEVELOPER_DIR を優先して返すため、外して問い合わせる
            if [ -x /usr/bin/xcode-select ] && dir="$(env -u DEVELOPER_DIR /usr/bin/xcode-select -p 2>/dev/null)"; then
              export DEVELOPER_DIR="$dir"
              # nix stdenv がエクスポートするツールチェーン変数を xcodebuild が拾うと
              # nix の ld でリンクして失敗する。Xcode のツールチェーンに任せる。
              unset SDKROOT CC CXX LD AR AS NM RANLIB STRIP OBJCOPY OBJDUMP SIZE STRINGS
            else
              echo "warning: Xcode が見つかりません。iOS アプリのビルドには Xcode が必要です。" >&2
            fi
          '';
        };
      }
    );
}
