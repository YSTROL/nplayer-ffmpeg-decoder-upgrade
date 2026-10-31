#!/usr/bin/env bash
# 交叉编译 FFmpeg 4.4.x (arm64-android) 并合并为单一 libffmpeg.so
# 目标：与 nPlayer 内置 FFmpeg 4.2.1 (Lavf58) ABI 兼容，可被 libnplayer.media.core.so 直接加载
set -euo pipefail

FF_VER="${FF_VER:-4.4.4}"
WITH_DAV1D="${WITH_DAV1D:-true}"
API=23
ARCH=aarch64
TRIPLE=aarch64-linux-android
PREFIX="$PWD/prefix"
mkdir -p "$PREFIX"

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
export PATH="$TOOLCHAIN/bin:$PATH"
CC=$TRIPLE$API-clang
CXX=$TRIPLE$API-clang++
export PKG_CONFIG="$TOOLCHAIN/bin/$TRIPLE-pkg-config" 2>/dev/null || true

echo "===== 1/4 下载源码 ====="
curl -sL "https://ffmpeg.org/releases/ffmpeg-$FF_VER.tar.xz" -o ffmpeg.tar.xz
tar xf ffmpeg.tar.xz
FF_SRC=$(ls -d ffmpeg-$FF_VER)

DAV1D_CFLAGS=""
DAV1D_LDFLAGS=""
DAV1D_PC=""

# ---------- 可选：编译 dav1d (AV1) ----------
if [ "$WITH_DAV1D" = "true" ]; then
  echo "===== 2/4 编译 dav1d ====="
  git clone --depth 1 --branch 1.4.3 https://code.videolan.org/videolan/dav1d.git || \
    git clone --depth 1 --branch 1.4.3 https://github.com/videolan/dav1d.git
  mkdir -p dav1d-build
  # meson 交叉文件
  cat > cross.txt <<EOF
[binaries]
c = '$CC'
ar = '$TOOLCHAIN/bin/llvm-ar'
nm = '$TOOLCHAIN/bin/llvm-nm'
strip = '$TOOLCHAIN/bin/llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOF
  # dav1d 需要 android 库路径；静态库必须以 PIC 方式编译
  if meson setup dav1d-build dav1d --cross-file cross.txt \
      -Dprefix="$PREFIX" -Dbuildtests=false -Dtests=false \
      -Ddefault_library=static -Db_staticpic=true --libdir=lib 2>&1 | tail -3; then
    ninja -C dav1d-build install >/dev/null 2>&1 && {
      DAV1D_CFLAGS="-I$PREFIX/include"
      DAV1D_LDFLAGS="$PREFIX/lib/libdav1d.a -llog"
      DAV1D_PC="$PREFIX/lib/pkgconfig"
      echo "dav1d 编译成功"
    }
  fi
  if [ -z "$DAV1D_LDFLAGS" ]; then
    echo "!! dav1d 编译失败，继续构建不含 AV1 的版本"
  fi
else
  echo "===== 2/4 跳过 dav1d ====="
fi

# ---------- 编译 FFmpeg（静态库） ----------
echo "===== 3/4 编译 FFmpeg $FF_VER ====="
LIB_FLAGS="--enable-static --disable-shared --disable-programs --disable-doc \
  --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
  --enable-avcodec --enable-avformat --enable-avutil --enable-swscale \
  --enable-swresample --enable-avfilter --enable-avdevice --enable-network \
  --enable-protocols --enable-demuxers --enable-muxers --enable-decoders \
  --enable-encoders --enable-filters --enable-parsers --enable-bsfs \
  --enable-indevs --enable-outdevs \
  --extra-cflags='-fPIC -O3' --extra-cxxflags='-fPIC -O3' \
  --extra-ldflags='-fPIC -lm -llog'"

if [ -n "$DAV1D_LDFLAGS" ]; then
  LIB_FLAGS="$LIB_FLAGS --enable-libdav1d \
    --extra-cflags=$DAV1D_CFLAGS \
    --extra-ldflags=$DAV1D_LDFLAGS \
    --extra-libs=-lpthread --extra-libs=-lm"
fi

cd "$FF_SRC"
PKG_CONFIG_PATH="${DAV1D_PC:-}" ./configure \
  --target-os=android \
  --arch=$ARCH --cpu=armv8-a \
  --enable-cross-compile \
  --cc=$CC --cxx=$CXX \
  --sysroot="$TOOLCHAIN/sysroot" \
  --prefix="$PREFIX" \
  --pkg-config-flags="--static" \
  --extra-ldflags="-lm -llog" \
  $LIB_FLAGS 2>&1 | tail -5

make -j"$(nproc)" >/dev/null
make install >/dev/null
cd ..

echo "===== 4/4 合并为单一 libffmpeg.so ====="
cat > merge.c <<'EOF'
// 防止链接器丢弃静态库：强制保留全部目标文件
void __ffmpeg_merge_marker(void) {}
EOF
$CC -fPIC -shared -o libffmpeg.so merge.c \
  -Wl,--whole-archive \
    "$PREFIX/lib/libavdevice.a" \
    "$PREFIX/lib/libavfilter.a" \
    "$PREFIX/lib/libavformat.a" \
    "$PREFIX/lib/libavcodec.a" \
    "$PREFIX/lib/libswresample.a" \
    "$PREFIX/lib/libswscale.a" \
    "$PREFIX/lib/libavutil.a" \
  -Wl,--no-whole-archive \
  $( [ -f "$PREFIX/lib/libdav1d.a" ] && echo "$PREFIX/lib/libdav1d.a" ) \
  -lm -llog -lz -landroid \
  -Wl,-soname,libffmpeg.so \
  -O3

$TOOLCHAIN/bin/llvm-strip libffmpeg.so
echo "完成: $(pwd)/libffmpeg.so"
