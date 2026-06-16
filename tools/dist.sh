#!/bin/sh
# Сборка дистрибутива: dist/unlha_<ver>.zip с unlha.exe, unlhaen.txt (англ.),
# unlha.txt (рус., CP866). Версия берётся из баннера src/unlha.asm. Текстовые
# файлы — с CRLF (DOS). Исходники описаний — tools/dist/unlhaen.txt и
# tools/dist/unlha.ru.txt (UTF-8).
set -e
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

for t in iconv zip; do
  command -v "$t" >/dev/null 2>&1 || { echo "Error: '$t' not found" >&2; exit 1; }
done
[ -f build/UNLHA.EXE ] || { echo "Error: build/UNLHA.EXE missing (run 'make exe')" >&2; exit 1; }

# Версия из баннера: "UNLHA X.Y - ..."
ver="$(sed -n 's/.*"UNLHA \([0-9.]*\) .*/\1/p' src/unlha.asm | head -1)"
[ -n "$ver" ] || ver="0.0"

stage="dist/stage"
rm -rf "$stage"; mkdir -p "$stage"

# Описания: CRLF; русское — в CP866.
sed 's/$/\r/' tools/dist/unlhaen.txt > "$stage/unlhaen.txt"
sed 's/$/\r/' tools/dist/unlha.ru.txt | iconv -f UTF-8 -t CP866 > "$stage/unlha.txt"
cp build/UNLHA.EXE "$stage/unlha.exe"

zip_path="dist/unlha_${ver}.zip"
rm -f "$zip_path"
( cd "$stage" && zip -j -X "../unlha_${ver}.zip" unlha.exe unlhaen.txt unlha.txt >/dev/null )

echo "Created $zip_path:"
unzip -l "$zip_path"
