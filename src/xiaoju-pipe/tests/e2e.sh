#!/bin/sh
# 不用下载模型的端到端测试：生成一个随机权重的小 Qwen3.5，然后
#   1. 单机 vs 主机 + 从机（两个进程走 TCP）输出一字不差；
#   2. 生成到一半从机进程被杀，再起一个从机：主机自动重连、重放，输出仍然和单机一字不差；
#   3. 从机一直起不来：主机重试几次后报错退出，不会卡死；
#   4. 旧连接没断干净（Wi‑Fi 掉线时对方收不到 FIN）：新主机连上来，从机丢掉旧连接改服务新的。
#   5. MTP 投机解码：单机 / 拆两段 / 中途断线，全猜对、猜对一部分、全猜错，输出都和普通解码一字不差。
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
echo "== 5. MTP 投机解码"
python3 tests/make_tiny_model.py "$T/tiny-mtp.gguf" --mtp > /dev/null
python3 tests/mtp_sparse.py "$T/tiny-mtp.gguf" "$T/mtp-only.gguf"
./build/xjpipe-host "$T/tiny.gguf" "$Q" --n 48 --ids "$T/ids.txt" > /dev/null 2>&1
spec() {  # 名字 输出文件 其余参数…
    name=$1; out=$2; shift 2
    "$@" > "$out" 2> "$out.err" || { cat "$out.err"; echo "$name：出错"; exit 1; }
    cmp -s "$T/solo.txt" "$out" || { cat "$out.err"; echo "$name：和普通解码不一样"; exit 1; }
    echo "$name：一致，$(grep 投机解码 "$out.err" | tail -1)"
}
# 随机权重的 MTP 基本猜不中；用 --oracle 拿正确答案当「猜的字」（每隔几个故意错一个），猜对的路径也走到
for k in 1 3 4; do
    spec "单机 猜$k 个 随机MTP" "$T/s$k.txt" ./build/xjpipe-host "$T/tiny.gguf" "$Q" --n 48 --draft $k --mtp "$T/mtp-only.gguf"
    for miss in 0 3 5; do
        spec "单机 猜$k 个 答案每$miss 错1" "$T/o$k$miss.txt" ./build/xjpipe-host "$T/tiny.gguf" "$Q" --n 48 --draft $k --mtp "$T/mtp-only.gguf" --oracle "$T/ids.txt" $miss
    done
done
spec "MTP 在模型文件里" "$T/emb.txt" ./build/xjpipe-host "$T/tiny-mtp.gguf" "$Q" --n 48 --draft 3 --oracle "$T/ids.txt" 5
./build/xjpipe-worker "$T/slice.gguf" --layers 2:6 --pin 4321 --port $PORT $WF 2> "$T/w5.log" &
W=$!
sleep 1
for miss in 0 3; do
    spec "拆两段 猜3 个 答案每$miss 错1" "$T/p$miss.txt" ./build/xjpipe-host "$T/tiny.gguf" "$Q" --worker 127.0.0.1 --port $PORT --pin 4321 --n 48 --draft 3 --mtp "$T/mtp-only.gguf" --oracle "$T/ids.txt" $miss
done
kill $W; wait $W 2>/dev/null || true
( ./build/xjpipe-worker "$T/slice.gguf" --layers 2:6 --pin 4321 --port $PORT --die-after 10 $WF || true
  ./build/xjpipe-worker "$T/slice.gguf" --layers 2:6 --pin 4321 --port $PORT $WF ) 2> "$T/w6.log" &
W=$!
sleep 1
spec "拆两段 中途断线" "$T/pr.txt" ./build/xjpipe-host "$T/tiny.gguf" "$Q" --worker 127.0.0.1 --port $PORT --pin 4321 --n 48 --draft 3 --mtp "$T/mtp-only.gguf" --oracle "$T/ids.txt" 5
pkill -f "xjpipe-worker $T" 2>/dev/null || true
wait $W 2>/dev/null || true
grep -q "重连了 1 次" "$T/pr.txt.err" || { cat "$T/pr.txt.err"; echo "主机没有重连"; exit 1; }
echo "端到端测试全部通过"
