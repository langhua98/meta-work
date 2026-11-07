package com.langhua98.xiaoju.remote

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicLong

/** 实时画面发到哪儿：云盘的直播通道（StreamClient），或者同一个 Wi-Fi 里直连的 iPhone（LanViewer）。 */
interface LiveSink {
    val watchers: Int          // 有几个人在看（0 = 没人看，别发）
    val isClosed: Boolean
    val sentFrames: Int
    val droppedFrames: Int
    fun send(frame: ByteArray): Boolean
    fun sendH264(msg: ByteArray, key: Boolean, limit: Long): Boolean
    fun sendAudio(msg: ByteArray): Boolean
    fun close()
}

/**
 * 同一个 Wi-Fi 下直连：iPhone 直接连这台手机看实时画面，不绕云盘服务器（服务器在国外，来回几百毫秒，上行也慢）。
 * 自己实现最小的 WebSocket 服务端，只够实时画面用。协议和云盘的直播通道一样：
 * 第一条文字消息 {"pub":true,"h264":true}，二进制消息的格式见 StreamClient，看的一端回的文字（ok）不用管。
 * 只收带着这次直播房间名的连接（房间名是随机的，放在指令里，同一个 Wi-Fi 里的别人猜不到）。
 * 不碰安卓的类，可以在电脑上跑测试。
 */
class LanServer(private val roomOk: (String) -> Boolean, private val onViewer: (LanViewer) -> Unit) {
    @Volatile private var server: ServerSocket? = null
    val port: Int get() = server?.localPort ?: 0

    /** 开始监听（8765 起找一个空的端口）。已经开着就直接返回。 */
    @Synchronized fun start(firstPort: Int = 8765): Boolean {
        if (server?.isClosed == false) return true
        for (p in firstPort until firstPort + 10) {
            val s = try { ServerSocket(p) } catch (e: IOException) { continue }
            server = s
            Thread({ acceptLoop(s) }, "lan-accept").apply { isDaemon = true; start() }
            return true
        }
        return false
    }

    @Synchronized fun close() { runCatching { server?.close() }; server = null }

    /** 这台手机在局域网里的地址（ip:端口），给 iPhone 直连用。 */
    fun addresses(): List<String> {
        val p = port
        if (p == 0) return emptyList()
        val out = ArrayList<String>()
        try {
            for (ni in NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()) {
                if (!ni.isUp || ni.isLoopback) continue
                for (a in ni.inetAddresses.toList()) {
                    if (a is Inet4Address && a.isSiteLocalAddress) out += "${a.hostAddress}:$p"
                }
            }
        } catch (e: Exception) { }
        return out
    }

    private fun acceptLoop(s: ServerSocket) {
        while (!s.isClosed) {
            val c = try { s.accept() } catch (e: IOException) { break }
            Thread({ handshake(c) }, "lan-hs").apply { isDaemon = true; start() }
        }
    }

    private fun handshake(c: Socket) {
        try {
            c.soTimeout = 5_000
            c.tcpNoDelay = true
            val input = BufferedInputStream(c.getInputStream())
            val lines = readHead(input) ?: run { c.close(); return }
            val parts = lines.first().split(" ")
            val headers = lines.drop(1).mapNotNull { l ->
                val i = l.indexOf(':'); if (i <= 0) null else l.substring(0, i).trim().lowercase() to l.substring(i + 1).trim()
            }.toMap()
            val key = headers["sec-websocket-key"]
            val target = parts.getOrNull(1) ?: ""
            val room = query(target)["room"] ?: ""
            val out = c.getOutputStream()
            if (parts.getOrNull(0) != "GET" || key == null || !target.startsWith("/stream") ||
                headers["upgrade"]?.lowercase() != "websocket") {
                out.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".toByteArray()); c.close(); return
            }
            if (!roomOk(room)) {
                out.write("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".toByteArray()); c.close(); return
            }
            out.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: ${accept(key)}\r\n\r\n").toByteArray())
            out.flush()
            c.soTimeout = 0
            val v = LanViewer(c, input)
            v.start()
            onViewer(v)
        } catch (e: Exception) {
            runCatching { c.close() }
        }
    }

    companion object {
        private const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

        fun accept(key: String): String {
            val sha = MessageDigest.getInstance("SHA-1").digest((key + GUID).toByteArray(Charsets.US_ASCII))
            return base64(sha)
        }

        /** 读 HTTP 请求头（到空行），最多 8 KB。 */
        fun readHead(input: InputStream): List<String>? {
            val buf = StringBuilder()
            var total = 0
            val lines = ArrayList<String>()
            while (total < 8192) {
                val b = input.read()
                if (b < 0) return null
                total++
                if (b == '\n'.code) {
                    val line = buf.toString().trimEnd('\r')
                    if (line.isEmpty()) return lines.takeIf { it.isNotEmpty() }
                    lines += line; buf.setLength(0)
                } else buf.append(b.toChar())
            }
            return null
        }

        fun query(target: String): Map<String, String> {
            val q = target.substringAfter('?', "")
            if (q.isEmpty()) return emptyMap()
            return q.split("&").mapNotNull {
                val i = it.indexOf('='); if (i <= 0) null
                else URLDecoder.decode(it.substring(0, i), "UTF-8") to URLDecoder.decode(it.substring(i + 1), "UTF-8")
            }.toMap()
        }

        /** 标准 Base64（不依赖 android.util，电脑上也能跑）。 */
        fun base64(b: ByteArray): String {
            val t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            val sb = StringBuilder()
            var i = 0
            while (i < b.size) {
                val n = (b[i].toInt() and 0xff shl 16) or ((if (i + 1 < b.size) b[i + 1].toInt() and 0xff else 0) shl 8) or
                    (if (i + 2 < b.size) b[i + 2].toInt() and 0xff else 0)
                sb.append(t[n shr 18 and 63]).append(t[n shr 12 and 63])
                sb.append(if (i + 1 < b.size) t[n shr 6 and 63] else '=')
                sb.append(if (i + 2 < b.size) t[n and 63] else '=')
                i += 3
            }
            return sb.toString()
        }

        /** 服务端发的 WebSocket 帧（不加掩码）。 */
        fun frame(opcode: Int, payload: ByteArray): ByteArray {
            val n = payload.size
            val head = when {
                n < 126 -> byteArrayOf((0x80 or opcode).toByte(), n.toByte())
                n < 65536 -> byteArrayOf((0x80 or opcode).toByte(), 126, (n shr 8).toByte(), n.toByte())
                else -> ByteArray(10).also { h ->
                    h[0] = (0x80 or opcode).toByte(); h[1] = 127
                    for (k in 0 until 8) h[2 + k] = (n.toLong() ushr (56 - 8 * k)).toByte()
                }
            }
            return head + payload
        }
    }
}

/**
 * 一个直连的观看端。发送在自己的线程上排队写（不卡编码器）；积压太多就丢，H.264 丢了等关键帧（和 StreamClient 一样）。
 * 收：看的一端回的 ok 不用管；ping 回 pong；close 就断开。
 */
class LanViewer(private val sock: Socket, private val input: InputStream) : LiveSink {
    @Volatile private var closed = false
    @Volatile private var sent = 0
    @Volatile private var dropped = 0
    @Volatile private var needKey = true
    private val q = LinkedBlockingQueue<ByteArray>()
    private val queued = AtomicLong(0)
    private val out = BufferedOutputStream(sock.getOutputStream(), 64 * 1024)

    override val watchers get() = if (closed) 0 else 1
    override val isClosed get() = closed
    override val sentFrames get() = sent
    override val droppedFrames get() = dropped
    val remote: String get() = sock.inetAddress?.hostAddress ?: "?"

    fun start() {
        enqueue(LanServer.frame(1, "{\"pub\":true,\"h264\":true}".toByteArray()))
        Thread({ writeLoop() }, "lan-write").apply { isDaemon = true; start() }
        Thread({ readLoop() }, "lan-read").apply { isDaemon = true; start() }
    }

    override fun send(frame: ByteArray): Boolean {
        if (closed) return false
        if (queued.get() > StreamClient.MAX_QUEUE) { dropped++; return false }
        enqueue(LanServer.frame(2, frame)); sent++
        return true
    }

    override fun sendH264(msg: ByteArray, key: Boolean, limit: Long): Boolean {
        if (closed) return false
        if (!key && needKey) { dropped++; return false }
        if (queued.get() > (if (key) limit * 2 else limit)) { needKey = true; dropped++; return false }
        enqueue(LanServer.frame(2, msg))
        needKey = false; sent++
        return true
    }

    override fun sendAudio(msg: ByteArray): Boolean {
        if (closed) return false
        if (queued.get() > StreamClient.MAX_AUDIO_QUEUE) { dropped++; return false }
        enqueue(LanServer.frame(2, msg))
        return true
    }

    override fun close() {
        if (closed) return
        closed = true
        q.offer(ByteArray(0))
        runCatching { sock.close() }
    }

    private fun enqueue(b: ByteArray) { queued.addAndGet(b.size.toLong()); q.offer(b) }

    private fun writeLoop() {
        try {
            while (!closed) {
                var b = q.take()
                if (b.isEmpty()) break
                // 把排着的一起写出去再 flush（少一些系统调用）
                while (true) {
                    out.write(b); queued.addAndGet(-b.size.toLong())
                    b = q.poll() ?: break
                    if (b.isEmpty()) { closed = true; break }
                }
                out.flush()
            }
        } catch (e: Exception) { } finally { close() }
    }

    private fun readLoop() {
        try {
            while (!closed) {
                val b0 = input.read(); val b1 = input.read()
                if (b0 < 0 || b1 < 0) break
                val op = b0 and 0x0f
                var len = (b1 and 0x7f).toLong()
                if (len == 126L) len = ((input.read() shl 8) or input.read()).toLong()
                else if (len == 127L) { len = 0; repeat(8) { len = (len shl 8) or input.read().toLong() } }
                if (len < 0 || len > 1 shl 16) break
                val mask = if (b1 and 0x80 != 0) ByteArray(4).also { readFully(it) } else null
                val p = ByteArray(len.toInt()).also { readFully(it) }
                if (mask != null) for (i in p.indices) p[i] = (p[i].toInt() xor mask[i % 4].toInt()).toByte()
                when (op) {
                    8 -> break                                   // 关闭
                    9 -> enqueue(LanServer.frame(10, p))         // ping → pong
                }
            }
        } catch (e: Exception) { } finally { close() }
    }

    private fun readFully(b: ByteArray) {
        var off = 0
        while (off < b.size) {
            val n = input.read(b, off, b.size - off)
            if (n < 0) throw IOException("closed")
            off += n
        }
    }
}
