package com.langhua98.xiaoju.remote

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class LanServerTest {
    private val ok = OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).build()

    private class Viewer : WebSocketListener() {
        val texts = LinkedBlockingQueue<String>()
        val bins = LinkedBlockingQueue<ByteArray>()
        val failed = CountDownLatch(1)
        var code = 0
        override fun onMessage(webSocket: WebSocket, text: String) { texts.add(text) }
        override fun onMessage(webSocket: WebSocket, bytes: ByteString) { bins.add(bytes.toByteArray()) }
        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { code = response?.code() ?: -1; failed.countDown() }
    }

    @Test fun handshakeRoomCheckFramesAndClose() {
        val viewers = CopyOnWriteArrayList<LanViewer>()
        val got = CountDownLatch(1)
        val server = LanServer(roomOk = { it == "遥控/B/视频/abc" }, onViewer = { viewers += it; got.countDown() })
        assertTrue(server.start(18765))
        val port = server.port
        try {
            // 房间名不对：403
            val bad = Viewer()
            ok.newWebSocket(Request.Builder().url("ws://127.0.0.1:$port/stream?room=guess").build(), bad)
            assertTrue(bad.failed.await(5, TimeUnit.SECONDS))
            assertEquals(403, bad.code)

            val v = Viewer()
            val ws = ok.newWebSocket(Request.Builder()
                .url("ws://127.0.0.1:$port/stream?room=%E9%81%A5%E6%8E%A7%2FB%2F%E8%A7%86%E9%A2%91%2Fabc&ack=1&window=8").build(), v)
            assertTrue(got.await(5, TimeUnit.SECONDS))
            assertEquals("{\"pub\":true,\"h264\":true}", v.texts.poll(5, TimeUnit.SECONDS))
            val lv = viewers[0]
            assertEquals(1, lv.watchers)

            // H.264：没有关键帧之前普通帧不发；关键帧之后按顺序到；大小不同的帧（含 64 KB 以上）都完整
            assertFalse(lv.sendH264(byteArrayOf(4, 0, 9), false, 1 shl 20))
            val key = ByteArray(70_000) { (it % 251).toByte() }.also { it[0] = 4; it[10] = 1 }
            assertTrue(lv.sendH264(key, true, 1 shl 20))
            assertTrue(lv.sendH264(ByteArray(300) { 7 }.also { it[0] = 4 }, false, 1 shl 20))
            assertTrue(lv.sendAudio(byteArrayOf(2, 1, 5)))
            assertArrayEquals(key, v.bins.poll(5, TimeUnit.SECONDS))
            assertEquals(300, v.bins.poll(5, TimeUnit.SECONDS)!!.size)
            assertArrayEquals(byteArrayOf(2, 1, 5), v.bins.poll(5, TimeUnit.SECONDS))
            // 看的一端回的 ok（带掩码的文字帧）不影响什么
            ws.send("ok"); ws.send("ok")
            assertTrue(lv.send(byteArrayOf(3, 0, 1)))
            assertArrayEquals(byteArrayOf(3, 0, 1), v.bins.poll(5, TimeUnit.SECONDS))

            // 看的一端关掉：这边知道了
            ws.close(1000, "bye")
            val end = System.currentTimeMillis() + 5_000
            while (!lv.isClosed && System.currentTimeMillis() < end) Thread.sleep(50)
            assertTrue(lv.isClosed)
            assertEquals(0, lv.watchers)
            assertFalse(lv.sendH264(key, true, 1 shl 20))
        } finally {
            server.close()
        }
    }

    @Test fun acceptKeyAndBase64() {
        // RFC 6455 里的例子
        assertEquals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", LanServer.accept("dGhlIHNhbXBsZSBub25jZQ=="))
        assertEquals("", LanServer.base64(ByteArray(0)))
        assertEquals("YQ==", LanServer.base64("a".toByteArray()))
        assertEquals("YWI=", LanServer.base64("ab".toByteArray()))
        assertEquals("YWJj", LanServer.base64("abc".toByteArray()))
        assertEquals(mapOf("room" to "遥控/B", "ack" to "1"), LanServer.query("/stream?room=%E9%81%A5%E6%8E%A7%2FB&ack=1"))
    }

    @Test fun fpsRangeAvoidsLowMinimum() {
        fun r(a: Int, b: Int) = intArrayOf(a, b)
        assertArrayEquals(r(15000, 30000), LiveSettings.pickFpsRange(listOf(r(7500, 30000), r(15000, 30000), r(30000, 30000), r(15000, 15000))))
        assertArrayEquals(r(30000, 30000), LiveSettings.pickFpsRange(listOf(r(4000, 30000), r(30000, 30000))))
        assertArrayEquals(r(10000, 24000), LiveSettings.pickFpsRange(listOf(r(5000, 24000), r(10000, 24000))))
        assertEquals(null, LiveSettings.pickFpsRange(emptyList()))
    }
}
