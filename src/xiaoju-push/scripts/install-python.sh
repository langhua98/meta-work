#!/bin/bash
# 把 Python 标准库装进编译好的 App（照 CPython 官方 iOS 指南「Install Target Specific Python Standard Library」
# 和「Prepare Python Binary Modules」两步做，只是放到编译之后由 workflow 调）：
#   1. Python.xcframework/ios-arm64/lib/ → App/python/lib/
#   2. lib-dynload 里每个 .so 改成 Frameworks/<模块名>.framework（iOS 只允许 Frameworks 里有可执行代码），
#      原位置留一个 .fwork 文件写着框架的位置，Python 按它去加载。
# 用法：install-python.sh <XiaojuPush.app> <Python.xcframework> <bundle id>
set -euo pipefail
APP=$1; XCF=$2; BID=$3

SLICE="$XCF/ios-arm64"
trap 'echo "::error::install-python.sh 第 $LINENO 行出错"; find "$XCF" -maxdepth 3 | head -40' ERR
mkdir -p "$APP/python/lib"
# 新版打包：纯 Python 的标准库在 xcframework 根目录的 lib/，二进制模块在各个 slice 的 lib-<架构>/；老版本都在 slice 的 lib/
if [ -d "$XCF/lib" ]; then
    rsync -a --delete "$XCF/lib/" "$APP/python/lib/"
    [ -d "$SLICE/lib-arm64" ] && rsync -a "$SLICE/lib-arm64/" "$APP/python/lib/"
else
    rsync -a --delete "$SLICE/lib/" "$APP/python/lib/"
fi
DYN=$(find "$APP/python/lib" -type d -name lib-dynload | head -1)
[ -n "$DYN" ] || { echo "::error::找不到 lib-dynload"; find "$APP/python/lib" -maxdepth 2; exit 1; }
STD=$(dirname "$DYN")
VER=$(basename "$STD")
echo "标准库：${STD#"$APP/"}"
[ -f "$STD/os.py" ] || { echo "::error::$STD 里没有 os.py（标准库不全）"; ls "$STD" | head; exit 1; }

# pip：留下 ensurepip 里带的 pip 安装包，放到 python/pip.whl（在 PYTHONPATH 里，python3 -m pip 直接从它跑）
whl=$(find "$STD/ensurepip" -name 'pip-*.whl' 2>/dev/null | head -1)
[ -n "$whl" ] || { echo "::error::找不到 ensurepip 里的 pip"; exit 1; }
cp "$whl" "$APP/python/pip.whl"

# 手机上用不到的：测试、图形界面、给编译用的东西（省二三十 MB）
rm -rf "$STD/test" "$STD"/*/tests "$STD/idlelib" "$STD/tkinter" "$STD/turtledemo" "$STD/turtle.py" \
       "$STD/ensurepip" "$STD/lib2to3" "$STD/pydoc_data" "$STD/config-"* "$APP/python/lib/pkgconfig" 2>/dev/null || true
find "$STD" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$APP/python/lib" -name '*.a' -delete

n=0
while IFS= read -r so; do
    name=$(basename "$so" | cut -d. -f1)          # _ssl.cpython-313-iphoneos.so → _ssl
    fw="Frameworks/$name.framework"
    mkdir -p "$APP/$fw"
    cat > "$APP/$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>$BID.python.$(echo "$name" | tr '_' '-')</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
    mv "$so" "$APP/$fw/$name"
    rel=${so#"$APP/"}
    echo "$fw/$name" > "${so%.so}.fwork"
    echo "${rel%.so}.fwork" > "$APP/$fw/$name.origin"
    n=$((n + 1))
done < <(find "$STD/lib-dynload" -name '*.so')
echo "Python $VER：标准库 $(du -sh "$APP/python" | cut -f1)，二进制模块 $n 个"
[ "$n" -gt 20 ] || { echo "::error::二进制模块太少（$n）"; exit 1; }
