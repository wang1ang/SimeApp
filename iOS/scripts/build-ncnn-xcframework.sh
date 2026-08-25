#!/usr/bin/env bash
set -euo pipefail

# Builds the CPU-only ncnn runtime used by Sime's optional GRU reranker.
# Output is intentionally ignored by Git: iOS/Dependencies/ncnn.xcframework.
root="$(cd "$(dirname "$0")/../.." && pwd)"
ncnn="$root/require/ncnn"
build="$root/build/ncnn-ios"
out="$root/iOS/Dependencies/ncnn.xcframework"

common=(
  -G Xcode
  -DNCNN_SHARED_LIB=OFF
  -DNCNN_VULKAN=OFF
  -DNCNN_OPENMP=OFF
  -DNCNN_BUILD_TOOLS=OFF
  -DNCNN_BUILD_EXAMPLES=OFF
  -DNCNN_BUILD_TESTS=OFF
  -DNCNN_BUILD_BENCHMARK=OFF
  -DNCNN_INSTALL_SDK=ON
  -DNCNN_C_API=OFF
  -DNCNN_PLATFORM_API=OFF
  -DNCNN_PIXEL=OFF
  -DNCNN_PIXEL_ROTATE=OFF
  -DNCNN_PIXEL_AFFINE=OFF
  -DNCNN_PIXEL_DRAWING=OFF
)

build_slice() {
  local name="$1" sysroot="$2" archs="$3"
  local dir="$build/$name"
  cmake -S "$ncnn" -B "$dir" -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES="$archs" "${common[@]}"
  cmake --build "$dir" --config Release -j"$(sysctl -n hw.ncpu)"
  cmake --install "$dir" --config Release --prefix "$dir/install"
}

build_slice device iphoneos arm64
build_slice simulator iphonesimulator 'arm64;x86_64'
rm -rf "$out"
xcodebuild -create-xcframework \
  -library "$build/device/install/lib/libncnn.a" -headers "$build/device/install/include/ncnn" \
  -library "$build/simulator/install/lib/libncnn.a" -headers "$build/simulator/install/include/ncnn" \
  -output "$out"
