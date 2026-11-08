package com.langhua98.xiaoju.remote

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 0.17：上下翻转、日期时间戳。 */
class ViewOptionsTest {
    /** 时间戳往回算的位置要和 MotionDetector.upright（转正的公式）对得上：原始像素 → 转正 → toRaw 回到同一个像素 */
    @Test fun toRawInvertsUpright() {
        val w = 64; val h = 48
        for (rot in listOf(0, 90, 180, 270)) {
            val uw = if (rot == 90 || rot == 270) h else w
            val uh = if (rot == 90 || rot == 270) w else h
            for (y in 0 until h) for (x in 0 until w) {
                val (a, b) = MotionDetector.upright((x + 0.5f) / w, (y + 0.5f) / h, rot)
                val u = (a * uw).toInt(); val v = (b * uh).toInt()
                assertEquals("rot $rot ($x,$y)", x to y, TimeStamp.toRaw(u, v, w, h, rot))
            }
        }
        assertNull(TimeStamp.toRaw(64, 0, 64, 48, 0))
        assertNull(TimeStamp.toRaw(0, 48, 64, 48, 0))
    }

    /** 转正以后的左上角，落在原始画面的哪个角（不翻转 / 翻转） */
    @Test fun stampCornerFollowsFlip() {
        val w = 640; val h = 480
        assertEquals(0 to 0, TimeStamp.toRaw(0, 0, w, h, 0))
        assertEquals((w - 1) to (h - 1), TimeStamp.toRaw(0, 0, w, h, 180))   // 翻转：左上角在原始画面的右下角
        assertEquals(0 to (h - 1), TimeStamp.toRaw(0, 0, w, h, 90))          // 竖着拿的手机（后摄常见 90°）
        assertEquals((w - 1) to 0, TimeStamp.toRaw(0, 0, w, h, 270))
    }

    @Test fun flipAndStampSettings() {
        val s = LiveSettings(false, 640, 50, 10, LiveSettings.H264)
        assertFalse(s.flip); assertTrue(s.stamp)
        val v = s.version
        assertEquals(listOf("画面上下翻转", "不印日期时间"), s.apply(JSONObject().put("flip", true).put("stamp", false)))
        assertTrue(s.flip); assertFalse(s.stamp)
        assertEquals("翻转不用重开相机", v, s.version)
        assertEquals(emptyList<String>(), s.apply(JSONObject().put("flip", true)))
    }
}
