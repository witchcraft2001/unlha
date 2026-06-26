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
    if [ "${UNLHA_IMAGE_ALL_LZH:-0}" != "1" ]; then
      case "$base" in
        CPM431.lzh|CPM431.LZH)
          echo "  $base  (ПРОПУЩЕН: UNLHA_IMAGE_ALL_LZH=1 для полного набора)"
          continue
          ;;
      esac
    fi
    upper="$(printf '%s' "$base" | tr 'a-z' 'A-Z')"
    mcopy -i "$image_path" -o "$f" "::$upper"
  done
  mixed_dir="$repo_root/build/mixed"
  python3 "$repo_root/tools/make_mixed_lha.py" "$mixed_dir"
  for f in "$mixed_dir"/*.LZH; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    mcopy -i "$image_path" -o "$f" "::$base"
  done
  # .lha — короткое 8.3-имя (длинные имена не влезают в FAT 8.3).
  # По умолчанию кладём только AttackOf...: его распаковка требует ~320K
  # свободного места на той же дискете. Полный набор: UNLHA_IMAGE_ALL_LHA=1.
  for f in "$repo_root"/test/*.lha "$repo_root"/test/*.LHA; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    if [ "${UNLHA_IMAGE_ALL_LHA:-0}" != "1" ]; then
      case "$base" in
        AttackOfTheGreenSmellyAliensFromPlanet27b6_v1.0.lha|AttackOfTheGreenSmellyAliensFromPlanet27b6_v1.0.LHA) ;;
        *)
          echo "  $base  (ПРОПУЩЕН: UNLHA_IMAGE_ALL_LHA=1 для полного набора)"
          continue
          ;;
      esac
    fi
    stem="$base"; stem="${stem%.*}"
    short="$(printf '%s' "$stem" | tr 'a-z' 'A-Z' | tr -cd 'A-Z0-9' | cut -c1-8)"
    if mcopy -i "$image_path" -o "$f" "::$short.LHA" 2>/dev/null; then
      echo "  $(basename "$f") -> $short.LHA"
    else
      echo "  $(basename "$f") -> $short.LHA  (ПРОПУЩЕН: дискета полна)"
    fi
  done
fi

echo "Created FAT12 image: $image_path"
mdir -i "$image_path" ::
