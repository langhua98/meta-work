#!/bin/sh
# 不用下载模型的端到端测试：生成一个随机权重的小 Qwen3.5，然后
#   1. 单机 vs 主机 + 从机（两个进程走 TCP）输出一字不差；
#   2. 生成到一半从机进程被杀，再起一个从机：主机自动重连、重放，输出仍然和单机一字不差；
#   3. 从机一直起不来：主机重试几次后报错退出，不会卡死；
#   4. 旧连接没断干净（Wi‑Fi 掉线时对方收不到 FIN）：新主机连上来，从机丢掉旧连接改服务新的。
#   make e2e        （需要 python3 + numpy）
# 环境变量 XJ_WORKER_FLAGS 可以给从机加参数（比如 macOS 上 --cpu）。
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
PORT=${XJ_PORT:-47391}
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"' EXIT
WF=${XJ_WORKER_FLAGS:-}

python3 tests/make_tiny_model.py "$T/tiny.gguf"
./build/gguf-slice "$T/tiny.gguf" "$T/slice.gguf" 2:6
Q="你好北京，the answer"

./build/xjpipe-host "$T/tiny.gguf" "$Q" --n 48 > "$T/solo.txt" 2> "$T/solo.err"

echo "== 1. 拆两段"
./build/xjpipe-worker "$T/slice.gguf" --layers 2:6 --pin 4321 --port $PORT $WF 2> "$T/w1.log" &
W=$!
sleep 1
./build/xjpipe-host "$T/tiny.gguf" "$Q" --worker 127.0.0.1 --port $PORT --pin 4321 --n 48 > "$T/split.txt" 2> "$T/split.err"
kill $W; wait $W 2>/dev/null || true
cmp "$T/solo.txt" "$T/split.txt" || { cat "$T/split.err" "$T/w1.log"; echo "拆两段和单机输出不一样"; exit 1; }
echo "一致"

echo "== 2. 从机中途被杀，再起一个"
# 第一个从机算完 12 批（预填充 5 批 + 生成 7 个字）就退出，接着马上起第二个
( ./build/xjpipe-worker "$T/slice.gguf" --layers 2:6 --pin 4321 --port $PORT --die-after 12 $WF || true
  ./build/xjpipe-worker "$T/slice.gguf" --layers 2:6 --pin 4321 --port $PORT $WF ) 2> "$T/w2.log" &
W=$!
sleep 1
./build/xjpipe-host "$T/tiny.gguf" "$Q" --worker 127.0.0.1 --port $PORT --pin 4321 --n 48 > "$T/reco.txt" 2> "$T/reco.err" || { cat "$T/reco.err" "$T/w2.log"; exit 1; }
pkill -f "xjpipe-worker $T" 2>/dev/null || true
wait $W 2>/dev/null || true
grep -q "die-after" "$T/w2.log" || { cat "$T/w2.log"; echo "从机没有按预期退出"; exit 1; }
grep -q "重连了 1 次" "$T/reco.err" || { cat "$T/reco.err"; echo "主机没有重连"; exit 1; }
cmp "$T/solo.txt" "$T/reco.txt" || { cat "$T/reco.err" "$T/w2.log"; echo "重连后输出和单机不一样"; exit 1; }
echo "一致（中途重连 1 次）"

echo "== 3. 从机起不来"
./build/xjpipe-worker "$T/slice.gguf" --layers 2:6 --pin 4321 --port $PORT --die-after 8 $WF 2> "$T/w3.log" &
W=$!
sleep 1
if ./build/xjpipe-host "$T/tiny.gguf" "$Q" --worker 127.0.0.1 --port $PORT --pin 4321 --n 48 --retry 2 > /dev/null 2> "$T/fail.err"; then
    echo "从机没了主机应该报错退出"; exit 1
fi
wait $W 2>/dev/null || true
grep -q "第 2 次重连" "$T/fail.err" || { cat "$T/fail.err"; echo "应该重试 2 次"; exit 1; }
echo "重试 2 次后报错退出：$(tail -1 "$T/fail.err")"

echo "== 4. 旧连接挂着不动，新主机照样能连上"
./build/xjpipe-worker "$T/slice.gguf" --layers 2:6 --pin 4321 --port $PORT $WF 2> "$T/w4.log" &
W=$!
sleep 1
# 一个连上来就一声不吭的「旧主机」
python3 -c "import socket,time; s=socket.create_connection(('127.0.0.1',$PORT)); time.sleep(60)" &
Z=$!
sleep 1
./build/xjpipe-host "$T/tiny.gguf" "$Q" --worker 127.0.0.1 --port $PORT --pin 4321 --n 48 > "$T/take.txt" 2> "$T/take.err" || { cat "$T/take.err" "$T/w4.log"; exit 1; }
kill $W $Z; wait $W $Z 2>/dev/null || true
grep -q "旧连接" "$T/w4.log" || { cat "$T/w4.log"; echo "从机没有丢掉旧连接"; exit 1; }
cmp "$T/solo.txt" "$T/take.txt" || { echo "输出不一样"; exit 1; }
echo "一致"
echo "端到端测试全部通过"
