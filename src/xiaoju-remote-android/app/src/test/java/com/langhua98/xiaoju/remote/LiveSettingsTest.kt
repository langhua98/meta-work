package com.langhua98.xiaoju.remote

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveSettingsTest {
    @Test fun lensAndWidthReopenCameraOthersDoNot() {
        val s = LiveSettings(false, 480, 50, 10)
        s.apply(JSONObject().put("quality", 70).put("fps", 5))
        assertEquals(0, s.version); assertEquals(0, s.tweak)
        assertEquals(70, s.quality); assertEquals(5, s.fps)

        s.apply(JSONObject().put("exposure", 0.5).put("zoom", 2.0).put("torch", true))
        assertEquals(0, s.version); assertEquals(1, s.tweak)
        assertEquals(1f, s.zoom, 0f)          // 超出范围截到 1
        assertTrue(s.torch)

        val changed = s.apply(JSONObject().put("lens", "front").put("width", 640))
        assertEquals(2, s.version); assertTrue(s.front); assertEquals(640, s.width)
        assertEquals(listOf("前置镜头", "清晰度 640"), changed)

        s.apply(JSONObject().put("lens", "front").put("width", 640))   // 没变就不重开
        assertEquals(2, s.version)
        s.apply(JSONObject().put("fps", 99).put("quality", 1))
        assertEquals(15, s.fps); assertEquals(20, s.quality)
    }

    @Test fun exposureIndex() {
        assertEquals(0, LiveSettings.exposureIndex(0f, -12, 12))
        assertEquals(12, LiveSettings.exposureIndex(1f, -12, 12))
        assertEquals(-12, LiveSettings.exposureIndex(-1f, -12, 12))
        assertEquals(1, LiveSettings.exposureIndex(0.5f, -2, 2))
        assertEquals(-2, LiveSettings.exposureIndex(-1f, -2, 3))
    }
}

class LiveSettingsCodecTest {
    private val s4 = listOf(1920 to 1080, 1440 to 1080, 1280 to 720, 1056 to 864, 960 to 720, 800 to 480,
        720 to 480, 640 to 480, 352 to 288, 320 to 240, 176 to 144)

    @Test fun pickSizeJpeg() {
        org.junit.Assert.assertEquals(320 to 240, LiveSettings.pickSize(s4, 320, false))
        org.junit.Assert.assertEquals(640 to 480, LiveSettings.pickSize(s4, 480, false))
        org.junit.Assert.assertEquals(1920 to 1080, LiveSettings.pickSize(s4, 4000, false))
    }

    @Test fun pickSizeH264OnlyEncoderSafeSizes() {
        org.junit.Assert.assertEquals(640 to 480, LiveSettings.pickSize(s4, 320, true))
        org.junit.Assert.assertEquals(640 to 480, LiveSettings.pickSize(s4, 640, true))
        org.junit.Assert.assertEquals(1280 to 720, LiveSettings.pickSize(s4, 960, true))
        // 一个合适的都没有：按 JPEG 的选（之后 LiveVideo 会退回 JPEG）
        org.junit.Assert.assertEquals(352 to 288, LiveSettings.pickSize(listOf(352 to 288, 176 to 144), 320, true))
    }

    @Test fun codecSwitchReopensCamera() {
        val s = LiveSettings(false, 480, 50, 10)
        org.junit.Assert.assertEquals(LiveSettings.JPEG, s.codec)
        val v = s.version
        s.apply(org.json.JSONObject().put("codec", "h264"))
        org.junit.Assert.assertEquals(LiveSettings.H264, s.codec)
        org.junit.Assert.assertEquals(v + 1, s.version)
        s.apply(org.json.JSONObject().put("codec", "h264"))
        org.junit.Assert.assertEquals(v + 1, s.version)          // 没变就不重开
        s.fallbackToJpeg()
        org.junit.Assert.assertEquals(LiveSettings.JPEG, s.codec)
        org.junit.Assert.assertEquals(LiveSettings.H264, LiveSettings(false, 480, 50, 10, "h264").codec)
        org.junit.Assert.assertEquals(LiveSettings.JPEG, LiveSettings(false, 480, 50, 10, "vp9").codec)
    }
}
