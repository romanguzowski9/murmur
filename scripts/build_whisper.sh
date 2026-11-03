#!/bin/zsh
# Builds whisper.cpp's whisper-server as one self-contained universal binary (Apple silicon + Intel, Metal
# shaders embedded, no Homebrew libraries), for bundling inside Murmur.app. Needs cmake.
# Output: build/whisper/whisper-server
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${WHISPER_CPP_VERSION:-1.9.5}
WORK=build/whisper
SRC="$WORK/whisper.cpp-$VERSION"
mkdir -p "$WORK"
if [[ ! -d "$SRC" ]]; then
  curl -fsSL "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$VERSION.tar.gz" | tar -xz -C "$WORK"
fi
build() {  # arch, extra cmake flags…
  local arch=$1; shift
  cmake -S "$SRC" -B "$WORK/build-$arch" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_SERVER=ON -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF "$@" > /dev/null
  cmake --build "$WORK/build-$arch" --config Release --target whisper-server -j "$(sysctl -n hw.ncpu)" > /dev/null
}
build arm64
# Every Intel Mac that runs macOS 15 has AVX2.
build x86_64 -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON
lipo -create "$WORK/build-arm64/bin/whisper-server" "$WORK/build-x86_64/bin/whisper-server" -output "$WORK/whisper-server"
otool -L "$WORK/whisper-server" | grep -v -E "/usr/lib/|/System/Library/|whisper-server" && { echo "unexpected dynamic library" >&2; exit 1; } || true
echo "Built $PWD/$WORK/whisper-server ($(lipo -archs "$WORK/whisper-server"), whisper.cpp $VERSION)"
