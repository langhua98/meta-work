#!/bin/sh
# 在电脑（Linux / Mac）上测物体识别：用手机上同一份 fastestdet.cpp、同一个模型，认几张照片。
#   NCNN_SRC=<ncnn 源码目录> sh run.sh        （没给就下载官方源码，版本和安卓用的一样）
# 照片用 scikit-image 安装包里自带的几张（宇航员、猫、咖啡），不用另外找。要 python3、numpy、Pillow、cmake。
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
MODELS="$HERE/../../app/src/main/assets/models"
VER=${NCNN_VERSION:-20240820}
WORK=${WORK:-/tmp/xj-detector-test}
mkdir -p "$WORK" && cd "$WORK"

# 1. 电脑版 ncnn
if [ ! -f ncnn/lib/cmake/ncnn/ncnnConfig.cmake ]; then
  SRC=$NCNN_SRC
  if [ -z "$SRC" ]; then
    [ -f src.zip ] || curl -fsSL -o src.zip "https://github.com/Tencent/ncnn/releases/download/$VER/ncnn-$VER-full-source.zip"
    [ -d src ] || unzip -q src.zip -d src
    SRC=$WORK/src
  fi
  mkdir -p ncnn-build && cd ncnn-build
  cmake "$SRC" -DCMAKE_BUILD_TYPE=Release -DNCNN_VULKAN=OFF -DNCNN_SHARED_LIB=OFF -DNCNN_PYTHON=OFF \
    -DNCNN_BUILD_TOOLS=OFF -DNCNN_BUILD_EXAMPLES=OFF -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX="$WORK/ncnn" > /dev/null
  cmake --build . -j 4 > /dev/null
  cmake --install . > /dev/null
  cd "$WORK"
fi

# 2. 照片 → 测试程序读的格式（BGR + 手机相机的 NV21）
if [ ! -f img/astronaut.png ]; then
  mkdir -p whl img
  python3 -m pip download --only-binary :all: --no-deps -q -d whl scikit-image
  python3 -I - <<'PY'
import glob, zipfile
z = zipfile.ZipFile(glob.glob("whl/scikit_image-*.whl")[0])
for n in ("astronaut", "chelsea", "coffee"):
    open("img/%s.png" % n, "wb").write(z.read("skimage/data/%s.png" % n))
from PIL import Image
a = Image.open("img/astronaut.png").convert("RGB")
two = Image.new("RGB", (a.width * 2, a.height)); two.paste(a, (0, 0)); two.paste(a, (a.width, 0))
two.save("img/two.png")   # 两个人：不能并成一个
PY
fi
python3 -I "$HERE/make_inputs.py" raw img/*.png > /dev/null

# 3. 编测试程序、跑
mkdir -p build && cd build
cmake "$HERE" -DNCNN_DIR="$WORK/ncnn" -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build . > /dev/null
fail=0
t() { ./test_fastestdet "$MODELS/fastestdet.param" "$MODELS/fastestdet.bin" "$WORK/raw/$1.raw" "$2" || fail=1; }
t astronaut 0x1   # 一个人（全身框和半身框只算一个）
t two 0x2         # 两个人
t chelsea 15x1    # 猫
t coffee 41       # 杯子
[ $fail = 0 ] && echo "物体识别测试全部通过" || { echo "物体识别测试有没通过的"; exit 1; }
