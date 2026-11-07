#!/bin/sh
# 编 ncnn（腾讯开源的手机端推理库，BSD 协议）给安卓被控端用：32 位 ARM、Android 4.2（API 17）。
# 编好装到 $PREFIX（默认 /opt/ncnn/armv7），安卓工程会自动找到（也可以用 -Pncnn.dir= 或环境变量 NCNN_DIR 指定）。
# 需要 NDK r23c（最后一个支持 Android 4.1～4.3 的）：$ANDROID_HOME/ndk/23.2.8568313
set -e
VER=${NCNN_VERSION:-20240820}
PREFIX=${PREFIX:-/opt/ncnn/armv7}
NDK=${ANDROID_NDK:-$ANDROID_HOME/ndk/23.2.8568313}
WORK=${WORK:-/tmp/ncnn-build}
# 一定要 r23：GitHub 的机器上 ANDROID_NDK 默认指向最新的 NDK（27+），用它编出来的 ncnn 和 App（r23c）链不到一起
# （缺 getauxval、fegetround、__libcpp_verbose_abort），而且新 NDK 不支持 4.2
if ! grep -q 'Pkg.Revision = 23\.' "$NDK/source.properties" 2>/dev/null; then
  echo "要 NDK r23c，现在是 $NDK（$(grep Pkg.Revision "$NDK/source.properties" 2>/dev/null)）。用 ANDROID_NDK=<r23c 的目录> 指定" >&2
  exit 1
fi
mkdir -p "$WORK" && cd "$WORK"
[ -f src.zip ] || curl -fsSL -o src.zip "https://github.com/Tencent/ncnn/releases/download/$VER/ncnn-$VER-full-source.zip"
[ -d src ] || unzip -q src.zip -d src
mkdir -p build && cd build
cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=armeabi-v7a -DANDROID_ARM_NEON=ON -DANDROID_PLATFORM=android-17 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DNCNN_VULKAN=OFF -DNCNN_OPENMP=ON -DNCNN_SHARED_LIB=OFF \
  -DNCNN_BUILD_TOOLS=OFF -DNCNN_BUILD_EXAMPLES=OFF -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_TESTS=OFF \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" ../src
ninja install
echo "ncnn 装好了：$PREFIX"
