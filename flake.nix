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
            nixfmt-rfc-style
          ];

          # Swift/Xcode は Nix で管理しない (macOS の Xcode 前提)。
          # ここでは存在確認と警告のみ行う。
          shellHook = ''
            echo "tendenko dev shell (go $(go version | cut -d' ' -f3))"
            if command -v xcodebuild >/dev/null 2>&1; then
              echo "Xcode: $(xcodebuild -version 2>/dev/null | head -n1)"
            else
              echo "warning: xcodebuild が見つかりません。iOS アプリのビルドには Xcode が必要です。" >&2
            fi
          '';
        };
      }
    );
}
