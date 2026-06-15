#!/usr/bin/env bash
# Сборка UNLHA.EXE через sjasmplus (сырой бинарь с EXE-заголовком внутри).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if ! command -v sjasmplus >/dev/null 2>&1; then
  echo "Error: sjasmplus is not installed or not in PATH" >&2
  exit 1
fi

mkdir -p "$repo_root/build"

sjasmplus --nologo --fullpath \
  --lst="$repo_root/build/UNLHA.lst" \
  --sym="$repo_root/build/UNLHA.sym" \
  --raw="$repo_root/build/UNLHA.EXE" \
  "$repo_root/src/unlha.asm"

echo "Built $repo_root/build/UNLHA.EXE ($(wc -c < "$repo_root/build/UNLHA.EXE") bytes)"
