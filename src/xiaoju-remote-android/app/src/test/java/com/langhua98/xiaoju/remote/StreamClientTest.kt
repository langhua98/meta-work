package com.langhua98.xiaoju.remote

import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.util.concurrent.TimeUnit

class StreamClientTest {

    @Test fun frameHeader() {
        val f = StreamClient.frame(byteArrayOf(7, 8), 270)
        assertEquals(1, f[0].toInt())   // 类型：JPEG
        assertEquals(3, f[1].toInt())   // 270° / 90
        assertEquals(7, f[2].toInt())
        assertEquals(4, f.size)
        assertEquals(0, StreamClient.frame(byteArrayOf(), -360)[1].toInt())
    }

    @Test fun pubUrl() {
        assertEquals(
            "wss://x.hf.space/api/agent/v1/stream?role=pub&room=%E9%81%A5%E6%8E%A7%2FB%2F%E8%A7%86%E9%A2%91%2Fab",
            StreamClient.pubUrl("https://x.hf.space/", "遥控/B/视频/ab"))
        assertTrue(StreamClient.pubUrl("http://127.0.0.1:1", "r").startsWith("ws://127.0.0.1:1/"))
    }

    /**
     * 联调：设了 STREAM_TEST_URL（比如 http://127.0.0.1:18080）才跑，要先起好服务端和观看端
     * （xiaoju-cloud 的直播通道）。每秒推 10 帧、每帧 40 KB，帧里带发送时间，观看端算延迟。
     * 观看端走了以后，这边要在 1 秒内发现「没人看了」。
     */
    @Test fun liveAgainstServer() {
        val base = System.getenv("STREAM_TEST_URL")
        assumeTrue("没设 STREAM_TEST_URL，跳过联调", base != null)
        val room = System.getenv("STREAM_TEST_ROOM") ?: "遥控/测试机/视频/test"
        val seconds = (System.getenv("STREAM_TEST_SECONDS") ?: "8").toInt()
        val ok = OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).pingInterval(20, TimeUnit.SECONDS).build()
        val c = StreamClient(ok, StreamClient.pubUrl(base!!, room), "xa_test")
        val connected = c.connect(5000)
        assertTrue("连不上：${c.error}", connected)

        val payload = ByteArray(40 * 1024)
        val end = System.currentTimeMillis() + seconds * 1000L
        var stoppedAt = 0L
        while (System.currentTimeMillis() < end) {
            if (c.nobodyWatching(5_000, 1_000)) { stoppedAt = System.currentTimeMillis(); break }
            ByteBuffer.wrap(payload).putLong(System.currentTimeMillis())
            if (c.subs > 0) c.send(StreamClient.frame(payload, 90))
            Thread.sleep(100)
        }
        println("推流端：发出 ${c.sent} 帧，丢 ${c.dropped} 帧，最后观看人数 ${c.subs}，" +
            if (stoppedAt > 0) "没人看了自动停" else "到时间停")
        c.close()
        assertTrue("一帧都没发出去", c.sent > 0)
    }
}
