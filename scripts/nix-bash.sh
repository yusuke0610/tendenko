#!/bin/sh
# Makefile の SHELL。全レシピ行を nix develop (flake.nix の devShell) の中で実行する。
# - すでに nix シェル内 (direnv 含む) なら二重起動しない
# - nix が無い環境 (CI ランナー等) では素の bash で実行する
# macOS 標準の make 3.81 は .SHELLFLAGS 非対応のため、SHELL 差し替えはこのスクリプトで行う。
if [ -n "$IN_NIX_SHELL" ] || ! command -v nix >/dev/null 2>&1; then
  exec bash "$@"
fi
# path:. で参照する: git ワークツリーが dirty でも警告を出さない
exec nix develop path:. --command bash "$@"
