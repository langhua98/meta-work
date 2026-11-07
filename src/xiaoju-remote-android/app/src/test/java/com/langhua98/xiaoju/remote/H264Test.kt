package com.langhua98.xiaoju.remote

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class H264Test {
    private fun b(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test fun nalTypesWithBothStartCodes() {
        // SPS(4 字节起始码) PPS(3 字节) IDR
        val s = b(0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9)
        assertEquals(listOf(7, 8, 5), H264.nalTypes(s))
        assertTrue(H264.hasKeyframe(s))
        assertTrue(H264.startsWithSps(s))
        val p = b(0, 0, 0, 1, 0x41, 7, 7)   // 普通帧
        assertEquals(listOf(1), H264.nalTypes(p))
        assertFalse(H264.hasKeyframe(p))
        assertFalse(H264.startsWithSps(p))
        assertEquals(emptyList<Int>(), H264.nalTypes(b(0, 0)))
    }

    @Test fun nv21Conversions() {
        // 4×2：Y 8 字节，色度 4 字节（NV21 = V U V U）
        val nv21 = b(1, 2, 3, 4, 5, 6, 7, 8, 'V'.code, 'U'.code, 'v'.code, 'u'.code)
        val out = ByteArray(12)
        H264.nv21ToNv12(nv21, out, 4, 2)
        assertArrayEquals(b(1, 2, 3, 4, 5, 6, 7, 8, 'U'.code, 'V'.code, 'u'.code, 'v'.code), out)
        H264.nv21ToI420(nv21, out, 4, 2)
        assertArrayEquals(b(1, 2, 3, 4, 5, 6, 7, 8, 'U'.code, 'u'.code, 'V'.code, 'v'.code), out)
    }

    @Test fun bitrateFollowsChoiceNotCameraSize() {
        val smooth = H264.bitrate(320, 10, 50)
        val hd = H264.bitrate(640, 10, 50)
        assertTrue("流畅 should use less than 高清: $smooth vs $hd", smooth < hd)
        assertTrue(H264.bitrate(640, 10, 85) > hd)
        assertTrue(H264.bitrate(640, 15, 50) > hd)
        assertEquals(150_000, H264.bitrate(240, 1, 20))          // 下限
        assertEquals(4_000_000, H264.bitrate(1280, 30, 90))      // 上限
        assertTrue(hd in 300_000..700_000)                       // 640×480 10 帧 中等画质：几百 kbps（JPEG 要 2 Mbps 上下）
    }

    @Test fun encoderSafeSizes() {
        assertTrue(H264.sizeOk(640, 480))
        assertTrue(H264.sizeOk(1280, 720))
        assertFalse(H264.sizeOk(320, 240))     // 76800 不是 2048 的倍数
        assertFalse(H264.sizeOk(1920, 1080))   // 1080 不是 16 的倍数
        assertFalse(H264.sizeOk(0, 0))
    }

    @Test fun h264MessageHeader() {
        val m = StreamClient.h264(b(0, 0, 1, 0x65), 90, 0x0102030405060708L, true)
        assertEquals(listOf(4, 1, 1, 2, 3, 4, 5, 6, 7, 8, 1, 0, 0, 1, 0x65), m.map { it.toInt() })
        assertEquals(0, StreamClient.h264(b(1), 0, 0, false)[10].toInt())
    }
}
