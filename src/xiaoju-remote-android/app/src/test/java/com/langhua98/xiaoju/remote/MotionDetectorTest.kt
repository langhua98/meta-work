package com.langhua98.xiaoju.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

class MotionDetectorTest {
    private val w = 640
    private val h = 480
    private val rnd = Random(1)

    /** 一帧：渐变背景 + 噪点，可以加一个亮方块（x, y 是左上角），整体再加 light 亮度。 */
    private fun frame(box: Pair<Int, Int>? = null, light: Int = 0, noise: Double = 6.0): ByteArray {
        val f = ByteArray(w * h * 3 / 2)
        for (y in 0 until h) for (x in 0 until w) {
            var v = 60 + x / 8 + y / 10 + light + (rnd.nextGaussian() * noise).toInt()
            if (box != null && x in box.first until box.first + 90 && y in box.second until box.second + 120) v = 220
            f[y * w + x] = v.coerceIn(0, 255).toByte()
        }
        return f
    }

    private fun warmUp(d: MotionDetector) { repeat(15) { assertFalse(d.analyze(frame(), w, h)) } }

    @Test fun stillNoisySceneIsQuiet() {
        val d = MotionDetector()
        repeat(60) { assertFalse("frame $it", d.analyze(frame(noise = 10.0), w, h)) }
    }

    @Test fun somethingWalkingInIsDetected() {
        val d = MotionDetector()
        warmUp(d)
        var hit = false
        for (i in 0 until 6) if (d.analyze(frame(100 + i * 30 to 200), w, h)) hit = true
        assertTrue("moving box should trigger, score ${d.score}", hit)
    }

    @Test fun singleGlitchIsIgnored() {
        val d = MotionDetector()
        warmUp(d)
        assertFalse(d.analyze(frame(300 to 200), w, h))   // 只有一帧（比如一只飞虫）
        assertFalse(d.analyze(frame(), w, h))
        assertFalse(d.analyze(frame(), w, h))
    }

    @Test fun lightsOnIsNotMotion() {
        val d = MotionDetector()
        warmUp(d)
        // 整体变亮（自动曝光、开灯）：减掉整体变化，不算动
        repeat(10) { assertFalse("light $it", d.analyze(frame(light = 50), w, h)) }
    }

    @Test fun lowSensitivityNeedsBiggerChange() {
        val d = MotionDetector().apply { sensitivity = 1 }
        warmUp(d)
        // 一个很小的东西（20×20）在动：低灵敏度不报
        var hit = false
        for (i in 0 until 6) {
            val f = frame()
            for (y in 200 until 220) for (x in 100 + i * 20 until 120 + i * 20) f[y * w + x] = 230.toByte()
            if (d.analyze(f, w, h)) hit = true
        }
        assertFalse(hit)
    }

    @Test fun onlyWatchedRegionCounts() {
        // 画面要顺时针转 90 度才正（手机竖着拿）。只看转正后的上半部分 = 相机原始画面的左半边
        val d = MotionDetector()
        d.setRegions(listOf(floatArrayOf(0f, 0f, 1f, 0.5f)), 90)
        warmUp(d)
        var hit = false
        for (i in 0 until 6) if (d.analyze(frame(400 + i * 20 to 200), w, h)) hit = true   // 右半边在动
        assertFalse("motion outside the region must not count", hit)
        for (i in 0 until 6) if (d.analyze(frame(40 + i * 20 to 200), w, h)) hit = true    // 左半边在动
        assertTrue("motion inside the region counts", hit)
    }

    @Test fun uprightMapping() {
        assertEquals(1f to 0f, MotionDetector.upright(0f, 0f, 90))   // 左上 → 右上
        assertEquals(1f to 1f, MotionDetector.upright(1f, 0f, 90))   // 右上 → 右下
        assertEquals(0f to 1f, MotionDetector.upright(0f, 0f, 270))  // 左上 → 左下
        assertEquals(1f to 1f, MotionDetector.upright(0f, 0f, 180))
        assertEquals(0.25f to 0.75f, MotionDetector.upright(0.25f, 0.75f, 0))
    }
}
