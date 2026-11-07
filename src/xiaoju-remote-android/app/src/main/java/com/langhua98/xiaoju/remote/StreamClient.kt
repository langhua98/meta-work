package com.langhua98.xiaoju.remote

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 直播推流端：连云盘服务端的 /api/agent/v1/stream?role=pub（WebSocket 长连接），一帧一条二进制消息。
 * 服务端会发 {"subs":N} 告诉这边有几个人在看；没人看了就该停。
 * 只用 OkHttp，不碰安卓的类，可以在电脑上直接跑测试（见 src/test）。
 *
 * 消息格式（和小橘推送的查看器、服务端说明一致），第 1 字节是类型：
 *   1 = 画面（旧查看器）：[1][角度/90][JPEG]
 *   3 = 画面带时间戳：   [3][角度/90][采集时间 8 字节，毫秒，大端][JPEG]
 *   2 = 声音：           [2][格式][采集时间 8 字节][数据]，格式 1 = μ-law 16 kHz 单声道，2 = μ-law 8 kHz
 *   4 = H.264 画面：     [4][角度/90][采集时间 8 字节][标志，第 0 位 = 关键帧][Annex-B 数据，关键帧前面带 SPS/PPS]
 * 时间戳是被控端自己的单调时钟（System.nanoTime），只用来让看的一端把声音和画面排在同一条时间线上。
 */
class StreamClient(private val client: OkHttpClient, private val url: String, private val token: String) {

    @Volatile var subs = -1          // 现在几个人在看；-1 = 服务端还没说
        private set
    @Volatile var closed = false
        private set
    @Volatile var error: String? = null
        private set
    @Volatile var sent = 0           // 发出去的帧
        private set
    @Volatile var dropped = 0        // 网络跟不上丢掉的帧
        private set

    @Volatile private var needKey = true   // H.264：丢过帧，等关键帧
    @Volatile private var everWatched = false
    @Volatile private var zeroSince = 0L
    private var ws: WebSocket? = null
    private val opened = CountDownLatch(1)

    /** 连上服务端。成功返回 true；失败时 error 里是原因（比如「HTTP 404」= 服务端还没有直播通道）。 */
    fun connect(timeoutMs: Long = 20_000): Boolean {
        val req = Request.Builder().url(url).header("Authorization", "Bearer $token").build()
        ws = client.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { opened.countDown() }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val n = SUBS.find(text)?.groupValues?.get(1)?.toIntOrNull() ?: return
                subs = n
                if (n > 0) { everWatched = true; zeroSince = 0L }
                else if (zeroSince == 0L) zeroSince = System.currentTimeMillis()
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                if (error == null && code != 1000) error = "服务端断开（$code${if (reason.isBlank()) "" else " $reason"}）"
                closed = true
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { closed = true }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                error = response?.let { "HTTP ${it.code()}" } ?: (t.message ?: t.javaClass.simpleName)
                closed = true
                opened.countDown()
            }
        })
        opened.await(timeoutMs, TimeUnit.MILLISECONDS)
        if (opened.count > 0) { error = "连接超时"; close(); return false }
        if (closed && error == null) error = "连上就被断开了"
        return !closed
    }

    /** 发一帧。发送队列里积压太多（网络跟不上）就丢掉这一帧，保证对面看到的总是新画面。 */
    fun send(frame: ByteArray): Boolean {
        val w = ws ?: return false
        if (closed) return false
        if (w.queueSize() > MAX_QUEUE) { dropped++; return false }
        val ok = w.send(ByteString.of(frame, 0, frame.size))
        if (ok) sent++ else dropped++
        return ok
    }

    /**
     * 发一帧 H.264。普通帧要靠前面的帧才能解，不能随便丢：一旦丢了（积压超过 limit 字节、没人看），
     * 后面的普通帧都不发，等下一个关键帧。返回 false = 没发（该要一个关键帧了）。
     */
    fun sendH264(msg: ByteArray, key: Boolean, limit: Long): Boolean {
        val w = ws ?: return false
        if (closed) return false
        if (subs <= 0) { needKey = true; return false }
        if (!key && needKey) { dropped++; return false }
        if (w.queueSize() > (if (key) limit * 2 else limit) || !w.send(ByteString.of(msg, 0, msg.size))) {
            needKey = true; dropped++; return false
        }
        needKey = false
        sent++
        return true
    }

    /** 发一包声音。声音不能随便丢（会咔哒响），积压到 1 MB（网络很差了）才丢。 */
    fun sendAudio(msg: ByteArray): Boolean {
        val w = ws ?: return false
        if (closed) return false
        if (w.queueSize() > MAX_AUDIO_QUEUE) { dropped++; return false }
        return w.send(ByteString.of(msg, 0, msg.size))
    }

    /** 该停了吗：开始后 startWaitMs 毫秒还没人来看，或者看的人都走了超过 leftWaitMs 毫秒。 */
    fun nobodyWatching(startWaitMs: Long, leftWaitMs: Long): Boolean {
        if (subs != 0 || zeroSince == 0L) return false
        return System.currentTimeMillis() - zeroSince >= if (everWatched) leftWaitMs else startWaitMs
    }

    fun close() {
        closed = true
        runCatching { ws?.close(1000, "bye") }
    }

    companion object {
        /** JPEG：发送队列最多积压多少字节，再多就丢帧（大约三四帧的量） */
        const val MAX_QUEUE = 128L * 1024
        const val MAX_AUDIO_QUEUE = 1024L * 1024
        const val AUDIO_ULAW_16K = 1
        const val AUDIO_ULAW_8K = 2

        /** 单调时钟，毫秒（画面和声音用同一个） */
        fun now(): Long = System.nanoTime() / 1_000_000

        /** 画面带时间戳：[3][角度/90][时间 8 字节][JPEG] */
        fun frameTs(jpeg: ByteArray, rotation: Int, ts: Long): ByteArray {
            val out = ByteArray(jpeg.size + 10)
            out[0] = 3
            out[1] = (((rotation % 360 + 360) % 360) / 90).toByte()
            putLong(out, 2, ts)
            System.arraycopy(jpeg, 0, out, 10, jpeg.size)
            return out
        }

        /** H.264：[4][角度/90][时间 8 字节][标志][Annex-B] */
        fun h264(data: ByteArray, rotation: Int, ts: Long, key: Boolean): ByteArray {
            val out = ByteArray(data.size + 11)
            out[0] = 4
            out[1] = (((rotation % 360 + 360) % 360) / 90).toByte()
            putLong(out, 2, ts)
            out[10] = if (key) 1 else 0
            System.arraycopy(data, 0, out, 11, data.size)
            return out
        }

        /** 声音：[2][格式][时间 8 字节][数据] */
        fun audio(data: ByteArray, codec: Int, ts: Long): ByteArray {
            val out = ByteArray(data.size + 10)
            out[0] = 2
            out[1] = codec.toByte()
            putLong(out, 2, ts)
            System.arraycopy(data, 0, out, 10, data.size)
            return out
        }

        private fun putLong(b: ByteArray, at: Int, v: Long) {
            for (i in 0 until 8) b[at + i] = (v ushr (56 - 8 * i)).toByte()
        }
        private val SUBS = Regex("\"subs\"\\s*:\\s*(\\d+)")

        /** 拼一帧：类型 + 角度 + JPEG */
        fun frame(jpeg: ByteArray, rotation: Int): ByteArray {
            val out = ByteArray(jpeg.size + 2)
            out[0] = 1
            out[1] = (((rotation % 360 + 360) % 360) / 90).toByte()
            System.arraycopy(jpeg, 0, out, 2, jpeg.size)
            return out
        }

        /** https://… → wss://…/api/agent/v1/stream?room=…&role=pub */
        fun pubUrl(base: String, room: String): String {
            val b = base.trimEnd('/').replaceFirst(Regex("^http"), "ws")
            return "$b/api/agent/v1/stream?role=pub&room=" +
                java.net.URLEncoder.encode(room, "UTF-8").replace("+", "%20")
        }
    }
}
