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

echo "===== 1/4 下载源码 ====="
curl -sL "https://ffmpeg.org/releases/ffmpeg-$FF_VER.tar.xz" -o ffmpeg.tar.xz
tar xf ffmpeg.tar.xz
FF_SRC=$(ls -d ffmpeg-$FF_VER)

# nPlayer 加载外部解码器时会通过 dlsym 取 av_version_info() 的返回串校验版本，
# 只接受内置版的 "4.2.1"，报新版本会被判定"已更新、不兼容"而拒绝加载。
# 这里仅改上报的版本串（VERSION 文件 -> FFMPEG_VERSION），不改变实际代码与 ABI：
# 4.4.4 与 4.2.1 同属 Lavf58 主版本，ABI 兼容。
echo "4.2.1" > "$FF_SRC/VERSION"

# ---------- 可选：编译 dav1d (AV1) ----------
DAV1D_STATIC=""
if [ "$WITH_DAV1D" = "true" ]; then
  echo "===== 2/4 编译 dav1d ====="
  git clone --depth 1 --branch 1.4.3 https://github.com/videolan/dav1d.git
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
  if meson setup build-dav1d dav1d \
      --cross-file cross.txt \
      -Dprefix="$PREFIX" \
      -Ddefault_library=static \
      -Db_staticpic=true \
      -Denable_tests=false -Denable_tools=false \
      --libdir=lib; then
    ninja -C build-dav1d install
    if [ -f "$PREFIX/lib/libdav1d.a" ]; then
      DAV1D_STATIC="$PREFIX/lib/libdav1d.a"
      echo "dav1d 编译成功: $DAV1D_STATIC"
    fi
  fi
  [ -z "$DAV1D_STATIC" ] && echo "!! dav1d 编译失败，继续构建不含 AV1 的版本（完整错误见上方输出）"
else
  echo "===== 2/4 跳过 dav1d ====="
fi

# ---------- 编译 FFmpeg（静态库，全部用数组传参避免引号拆分） ----------
echo "===== 3/4 编译 FFmpeg $FF_VER ====="
FF_ARGS=(
  --target-os=android
  --arch=$ARCH --cpu=armv8-a
  --enable-cross-compile
  --cc=$CC --cxx=$CXX
  --sysroot="$TOOLCHAIN/sysroot"
  --prefix="$PREFIX"
  --pkg-config-flags=--static
  --enable-static --disable-shared
  --disable-programs
  --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages
  --enable-avcodec --enable-avformat --enable-avutil --enable-swscale
  --enable-swresample --enable-avfilter --enable-avdevice
  --enable-network --enable-protocols
  --enable-demuxers --enable-muxers
  --enable-decoders --enable-encoders
  --enable-filters --enable-parsers --enable-bsfs
  --enable-indevs --enable-outdevs
  --extra-cflags=-fPIC
  --extra-cflags=-O3
  --extra-libs=-lm
)
if [ -n "$DAV1D_STATIC" ]; then
  FF_ARGS+=(
    --enable-libdav1d
    --extra-cflags=-I"$PREFIX/include"
    --extra-ldflags="$DAV1D_STATIC"
  )
fi

cd "$FF_SRC"
if ! PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure "${FF_ARGS[@]}"; then
  echo "===== configure 失败，config.log 末尾 ====="
  tail -60 ffbuild/config.log
  exit 1
fi
make -j"$(nproc)" >/dev/null
make install >/dev/null
cd ..

echo "===== 4/4 合并为单一 libffmpeg.so ====="
cat > merge.c <<'EOF'
void __ffmpeg_merge_marker(void) {}
EOF
# 版本脚本：只导出公共 API，内部符号（ff_* / dav1d_* 等）标为 local
# 否则汇编里的绝对重定位会因符号可抢占而链接失败
cat > libffmpeg.ver <<'EOF'
{
  global:
    av*;
    sws_*;
    swr_*;
  local:
    *;
};
EOF
MERGE_ARGS=(
  -fPIC -shared -o libffmpeg.so merge.c
  -Wl,--whole-archive
    "$PREFIX/lib/libavdevice.a"
    "$PREFIX/lib/libavfilter.a"
    "$PREFIX/lib/libavformat.a"
    "$PREFIX/lib/libavcodec.a"
    "$PREFIX/lib/libswresample.a"
    "$PREFIX/lib/libswscale.a"
    "$PREFIX/lib/libavutil.a"
  -Wl,--no-whole-archive
  -Wl,--version-script="$PWD/libffmpeg.ver"
  -Wl,-Bsymbolic
  -lm -llog -lz -landroid
  -Wl,-soname,libffmpeg.so
  -O3
)
[ -n "$DAV1D_STATIC" ] && MERGE_ARGS+=("$DAV1D_STATIC")
$CC "${MERGE_ARGS[@]}"

$TOOLCHAIN/bin/llvm-strip libffmpeg.so
echo "完成: $(pwd)/libffmpeg.so"
