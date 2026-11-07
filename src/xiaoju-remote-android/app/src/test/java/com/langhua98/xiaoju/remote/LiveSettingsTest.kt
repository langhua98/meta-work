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
