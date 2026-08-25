#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE_ROOT="${SIME_ENGINE_ROOT:-$ROOT/require/Sime}"
BUILD_DIR="${NATIVE_CONTRACT_BUILD_DIR:-$ROOT/.local/NativeContractBuild}"
DICT="$ENGINE_ROOT/save/sime.dict"
COUNT="$ENGINE_ROOT/save/sime.cnt"

for model in "$DICT" "$COUNT"; do
  if [[ ! -f "$model" ]]; then
    printf 'Missing generated Sime model: %s\n' "$model" >&2
    exit 1
  fi
done

cmake \
  -S "$ENGINE_ROOT" \
  -B "$BUILD_DIR" \
  -DBUILD_TESTING=OFF \
  -DSIME_BUILD_TOOLS=OFF \
  -DSIME_ENABLE_NCNN=OFF
cmake --build "$BUILD_DIR" --target sime_core --parallel

"${CXX:-c++}" \
  -std=c++20 \
  -I "$ENGINE_ROOT/include" \
  -I "$ENGINE_ROOT/src" \
  "$ROOT/iOS/NativeTests/native_decoder_contract.cc" \
  "$BUILD_DIR/libsime_core.a" \
  -o "$BUILD_DIR/native_decoder_contract"

"$BUILD_DIR/native_decoder_contract" "$DICT" "$COUNT"
