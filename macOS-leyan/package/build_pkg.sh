#!/bin/bash
# Build a macOS .pkg installer for LeyanIME.
#
# Output: macOS/package/dist/Sime-<version>.pkg
# Install target: /Library/Input Methods/LeyanIME.app
set -euo pipefail

VERSION="${1:-1.0}"
IDENTIFIER="com.leyan.inputmethod.LeyanIME"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_REPO="$(cd "$ROOT/.." && pwd)"
ENGINE_ROOT="${SIME_ENGINE_ROOT:-$(cd "$APP_REPO/../Sime" && pwd)}"
BUILD="$ROOT/build"
APP_BUILT="$BUILD/Release/LeyanIME.app"
PAYLOAD="$ROOT/package/payload"
DIST="$ROOT/package/dist"
SCRIPTS="$ROOT/package/pkg-scripts"

echo ">> Configure & build (Release)"
cmake -S "$ROOT" -B "$BUILD" -G Xcode \
  -DSIME_ENGINE_ROOT="$ENGINE_ROOT" >/dev/null
cmake --build "$BUILD" --config Release >/dev/null

echo ">> Stage resources into bundle"
RES="$APP_BUILT/Contents/Resources"
mkdir -p "$RES"
cp -R "$ROOT/resources/en.lproj"    "$RES/"
cp -R "$ROOT/resources/zh_CN.lproj" "$RES/"
cp    "$ROOT/resources/sime.tiff"   "$RES/"
cp    "$ENGINE_ROOT/pipeline/output/sime.cnt"  "$RES/"
cp    "$ENGINE_ROOT/pipeline/output/sime.dict" "$RES/"
cp    "$ENGINE_ROOT/pipeline/output/gru.embedding.i8" "$RES/"
cp    "$ENGINE_ROOT/pipeline/output/gru.pinyin.ncnn.param" "$RES/"
cp    "$ENGINE_ROOT/pipeline/output/gru.pinyin.ncnn.bin" "$RES/"
cp    "$ENGINE_ROOT/pipeline/output/gru.t9.ncnn.param" "$RES/"
cp    "$ENGINE_ROOT/pipeline/output/gru.t9.ncnn.bin" "$RES/"

echo ">> Ad-hoc codesign"
codesign --force --deep --sign - "$APP_BUILT" >/dev/null

echo ">> Build payload tree"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD/Library/Input Methods"
cp -R "$APP_BUILT" "$PAYLOAD/Library/Input Methods/"

chmod +x "$SCRIPTS/postinstall"

echo ">> pkgbuild"
mkdir -p "$DIST"
OUT="$DIST/LeyanIME-$VERSION.pkg"
pkgbuild \
  --root "$PAYLOAD" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  --scripts "$SCRIPTS" \
  --ownership recommended \
  "$OUT"

echo
echo "Built: $OUT"
