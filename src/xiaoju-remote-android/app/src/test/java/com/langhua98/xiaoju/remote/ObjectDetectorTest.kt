package com.langhua98.xiaoju.remote

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

/** ObjectDetector 里不用 C++ 的部分，和 MotionDetector.moved()。模型本身在 tests/detector 里用电脑跑。 */
class ObjectDetectorTest {
    private fun det(cls: Int, x1: Float = 0.1f, y1: Float = 0.2f, x2: Float = 0.3f, y2: Float = 0.6f) =
        ObjectDetector.Detection(cls, 0.8f, x1, y1, x2, y2)

    @Test fun parseReadsSixFloatsPerBox() {
        val ds = ObjectDetector.parse(floatArrayOf(0f, 0.9f, 0.1f, 0.2f, 0.3f, 0.4f, 15f, 0.7f, 0.5f, 0.5f, 0.9f, 0.9f, 1f))
        assertEquals(2, ds.size)   // 最后多出来的一个数不算
        assertEquals("人", ds[0].name); assertTrue(ds[0].isPerson)
        assertEquals("猫", ds[1].name); assertEquals(0.5f, ds[1].x1)
    }

    @Test fun summaryPutsPeopleFirstThenByCount() {
        val ds = listOf(det(15), det(16), det(16), det(0), det(0))
        assertEquals("人×2、狗×2、猫", ObjectDetector.summary(ds))
        assertEquals("", ObjectDetector.summary(emptyList()))
        assertEquals(4, ObjectDetector.summaryOf(mapOf(1 to 1, 2 to 1, 3 to 1, 5 to 1, 7 to 1)).split("、").size)
    }

    @Test fun onlyThingsThatMoveCount() {
        assertTrue(det(0).canMove)    // 人
        assertTrue(det(2).canMove)    // 汽车
        assertTrue(det(15).canMove)   // 猫
        assertFalse(det(56).canMove)  // 椅子
        assertFalse(det(59).canMove)  // 床
        assertFalse(det(62).canMove)  // 电视
        assertEquals("东西", det(99).name)
    }

    @Test fun uprightRotatesTheBox() {
        val d = det(0, 0.1f, 0.2f, 0.3f, 0.6f)
        assertArrayEquals(floatArrayOf(0.1f, 0.2f, 0.3f, 0.6f), ObjectDetector.upright(d, 0), 1e-6f)
        // 顺时针 90 度：(x, y) → (1 - y, x)
        assertArrayEquals(floatArrayOf(0.4f, 0.1f, 0.8f, 0.3f), ObjectDetector.upright(d, 90), 1e-6f)
        assertArrayEquals(floatArrayOf(0.7f, 0.4f, 0.9f, 0.8f), ObjectDetector.upright(d, 180), 1e-6f)
        assertArrayEquals(floatArrayOf(0.2f, 0.7f, 0.6f, 0.9f), ObjectDetector.upright(d, 270), 1e-6f)
    }

    @Test fun movedOnlyWhereThePictureChanged() {
        val w = 640; val h = 480; val rnd = Random(1)
        fun frame(boxX: Int?): ByteArray {
            val f = ByteArray(w * h * 3 / 2)
            for (y in 0 until h) for (x in 0 until w) {
                var v = 60 + x / 8 + y / 10 + (rnd.nextGaussian() * 6).toInt()
                if (boxX != null && x in boxX until boxX + 90 && y in 200 until 320) v = 220
                f[y * w + x] = v.coerceIn(0, 255).toByte()
            }
            return f
        }
        val d = MotionDetector()
        repeat(15) { d.analyze(frame(null), w, h) }
        d.analyze(frame(100), w, h)
        // 亮方块在 x 100…190、y 200…320（0.16…0.30、0.42…0.67）
        assertTrue(d.moved(0.1f, 0.4f, 0.35f, 0.7f))
        assertFalse(d.moved(0.6f, 0.0f, 0.95f, 0.3f))   // 画面另一边没变
    }
}
