#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
ENGINE_ROOT="${SIME_ENGINE_ROOT:-$REPO_ROOT/require/Sime}"
BUILD="$ROOT/build"
APP="$BUILD/Release/LeyanIME.app"
DEST="$HOME/Library/Input Methods/LeyanIME.app"
DATA_ROOT="$ENGINE_ROOT/pipeline/output"

if [[ ! -f "$DATA_ROOT/sime.dict" ]]; then
  DATA_ROOT="$ENGINE_ROOT/save"
fi

if [[ ! -f "$BUILD/CMakeCache.txt" ]]; then
  cmake -S "$ROOT" -B "$BUILD" -G Xcode \
    -DSIME_ENGINE_ROOT="$ENGINE_ROOT"
fi

cmake --build "$BUILD" --config Release --target LeyanIME

RESOURCES="$APP/Contents/Resources"
mkdir -p "$RESOURCES"
for localization in en.lproj zh_CN.lproj; do
  rm -rf "$RESOURCES/$localization"
  ditto "$ROOT/resources/$localization" "$RESOURCES/$localization"
done
cp "$ROOT/resources/sime.tiff" "$RESOURCES/"
cp "$DATA_ROOT/sime.dict" "$DATA_ROOT/sime.cnt" "$RESOURCES/"
for model in gru.embedding.i8 gru.pinyin.ncnn.param gru.pinyin.ncnn.bin gru.t9.ncnn.param gru.t9.ncnn.bin; do
  if [[ -f "$DATA_ROOT/$model" ]]; then
    cp "$DATA_ROOT/$model" "$RESOURCES/"
  fi
done
codesign --force --deep --sign - "$APP" >/dev/null

mkdir -p "$(dirname "$DEST")"
pkill -x LeyanIME 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "Running 乐言输入法 from $DEST"
