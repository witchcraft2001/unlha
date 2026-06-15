#!/usr/bin/env bash
# Создание FAT12-образа дискеты (1.44M) для MAME: UNLHA.EXE + тест-архивы.
set -euo pipefail

if ! command -v mformat >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
  echo "Error: mtools is required (mformat and mcopy were not found)." >&2
  exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

exe_path="${1:-$repo_root/build/UNLHA.EXE}"
image_path="${2:-$repo_root/build/unlha.img}"

if [ ! -f "$exe_path" ]; then
  "$repo_root/tools/build.sh"
fi

mkdir -p "$(dirname "$image_path")"
rm -f "$image_path"

mformat -C -i "$image_path" -f 1440 ::
mcopy -i "$image_path" -o "$exe_path" ::UNLHA.EXE

# Тестовые архивы из каталога test/ (имена в верхнем регистре для DSS/FAT).
if [ -d "$repo_root/test" ]; then
  for f in "$repo_root"/test/*.lzh "$repo_root"/test/*.LZH; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    upper="$(printf '%s' "$base" | tr 'a-z' 'A-Z')"
    mcopy -i "$image_path" -o "$f" "::$upper"
  done
fi

echo "Created FAT12 image: $image_path"
mdir -i "$image_path" ::
