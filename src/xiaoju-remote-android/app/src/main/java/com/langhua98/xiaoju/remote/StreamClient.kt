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
 * 帧格式（和小橘推送的查看器、服务端说明一致）：第 1 字节 1 = JPEG 画面；第 2 字节 = 画面要顺时针转的角度 / 90；后面是 JPEG。
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
        /** 发送队列最多积压多少字节，再多就丢帧（大约几帧的量） */
        const val MAX_QUEUE = 256L * 1024
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
