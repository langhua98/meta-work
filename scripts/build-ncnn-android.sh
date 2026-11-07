#!/bin/sh
# 编 ncnn（腾讯开源的手机端推理库，BSD 协议）给安卓被控端用：32 位 ARM、Android 4.2（API 17）。
# 编好装到 $PREFIX（默认 /opt/ncnn/armv7），安卓工程会自动找到（也可以用 -Pncnn.dir= 或环境变量 NCNN_DIR 指定）。
# 需要 NDK r23c（最后一个支持 Android 4.1～4.3 的）：$ANDROID_HOME/ndk/23.2.8568313
set -e
VER=${NCNN_VERSION:-20240820}
PREFIX=${PREFIX:-/opt/ncnn/armv7}
NDK=${ANDROID_NDK:-$ANDROID_HOME/ndk/23.2.8568313}
WORK=${WORK:-/tmp/ncnn-build}
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
