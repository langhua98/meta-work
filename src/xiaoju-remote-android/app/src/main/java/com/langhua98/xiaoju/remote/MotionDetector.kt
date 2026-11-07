package com.langhua98.xiaoju.remote

/**
 * 移动侦测：只看亮度（NV21 前面的 Y 平面），把画面缩成 32×24 个小格，和慢慢更新的「背景」比。
 * - 整体变亮变暗（开灯、云挡太阳、相机自动曝光）先减掉，不算动；
 * - 门槛 = 灵敏度定的基本值 + 3 倍噪点（暗的时候噪点大，门槛自动变高）；
 * - 变了的格子超过一定比例、而且连续两次，才算「有动静」；
 * - 一大半格子都变了多半是相机被碰了 / 灯开关了：直接把背景换成现在的画面，不算动。
 * 每次大约看 1.2 万个点，老手机上每秒看 5 次也很轻松。不碰安卓的类，可以在电脑上跑测试。
 */
class MotionDetector(val cols: Int = 32, val rows: Int = 24) {
    /** 1…100，越大越灵敏 */
    @Volatile var sensitivity = 50
    /** 最近一次：变了的格子占检测区域的比例（0…1），调灵敏度时看 */
    @Volatile var score = 0f
        private set
    @Volatile var noise = 3f
        private set

    private var bg: FloatArray? = null
    private var bgW = 0
    private var bgH = 0
    private var mask: BooleanArray? = null   // 只检测这些格子（相机原始方向）；null = 全部
    private var regions: List<FloatArray> = emptyList()
    private var regionRot = 0
    private var warm = 0
    private var hits = 0
    private val cur = FloatArray(cols * rows)
    private val diff = FloatArray(cols * rows)

    /**
     * 只检测这些区域。rects 是看的一端在「转正以后的画面」上框的 [x, y, w, h]（0…1），
     * rot 是画面要顺时针转多少度才是正的（和直播一样）。空列表 = 整个画面。
     */
    @Synchronized fun setRegions(rects: List<FloatArray>, rot: Int) {
        regions = rects; regionRot = rot
        mask = if (rects.isEmpty()) null else BooleanArray(cols * rows) { i ->
            val sx = (i % cols + 0.5f) / cols
            val sy = (i / cols + 0.5f) / rows
            val (ux, uy) = upright(sx, sy, rot)
            rects.any { r -> ux >= r[0] && ux <= r[0] + r[2] && uy >= r[1] && uy <= r[1] + r[3] }
        }
    }

    /** 重新开始（换镜头、调亮度以后），前 2 秒不报。 */
    @Synchronized fun reset() { bg = null; warm = 0; hits = 0; score = 0f }

    /** 看一帧（y = NV21 数据，前 w*h 字节是亮度）。返回这一帧算不算「有动静」。 */
    @Synchronized fun analyze(y: ByteArray, w: Int, h: Int): Boolean {
        sample(y, w, h)
        val b = bg
        if (b == null || bgW != w || bgH != h) {
            bg = cur.copyOf(); bgW = w; bgH = h; warm = 0; hits = 0; score = 0f
            return false
        }
        val m = mask
        var n = 0
        var shift = 0f
        for (i in cur.indices) if (m == null || m[i]) { shift += cur[i] - b[i]; n++ }
        if (n == 0) return false
        shift /= n
        for (i in cur.indices) diff[i] = Math.abs(cur[i] - b[i] - shift)

        val s = sensitivity.coerceIn(1, 100)
        val thr = 5f + (100 - s) * 0.25f + 3f * noise
        var changed = 0
        for (i in cur.indices) if ((m == null || m[i]) && diff[i] > thr) changed++
        val frac = changed.toFloat() / n
        score = frac
        val need = maxOf(2f, n * (0.003f + (100 - s) / 100f * 0.03f))
        val moving = changed >= need

        warm++
        if (frac > 0.6f) {
            // 整个画面都变了：相机被碰了、灯开关了。重新当背景，不报
            System.arraycopy(cur, 0, b, 0, cur.size)
            hits = 0
            return false
        }
        // 噪点：没动的时候，差别的中位数
        if (!moving) noise = noise * 0.9f + median(diff, m) * 0.1f
        // 背景慢慢跟上现在的画面（有人站着不动，过一会儿也会变成背景）
        val a = if (moving) 0.02f else 0.1f
        for (i in cur.indices) b[i] += (cur[i] - b[i]) * a

        if (warm < 10) { hits = 0; return false }   // 刚开始曝光还在变
        hits = if (moving) hits + 1 else 0
        return hits >= 2
    }

    /** 每格的平均亮度：格子里每隔 step 个点取一个。 */
    private fun sample(y: ByteArray, w: Int, h: Int) {
        val cw = w / cols
        val ch = h / rows
        val step = maxOf(1, minOf(cw, ch) / 4)
        for (r in 0 until rows) for (c in 0 until cols) {
            var sum = 0
            var k = 0
            var yy = r * ch + step / 2
            while (yy < (r + 1) * ch) {
                var xx = c * cw + step / 2
                val row = yy * w
                while (xx < (c + 1) * cw) { sum += y[row + xx].toInt() and 0xff; k++; xx += step }
                yy += step
            }
            cur[r * cols + c] = if (k > 0) sum.toFloat() / k else 0f
        }
    }

    private fun median(d: FloatArray, m: BooleanArray?): Float {
        val v = if (m == null) d.copyOf() else d.filterIndexed { i, _ -> m[i] }.toFloatArray()
        if (v.isEmpty()) return noise
        v.sort()
        return v[v.size / 2]
    }

    companion object {
        /** 相机原始画面上的点 (x, y)（0…1）→ 顺时针转 rot 度以后的位置。 */
        fun upright(x: Float, y: Float, rot: Int): Pair<Float, Float> = when ((rot % 360 + 360) % 360) {
            90 -> (1 - y) to x
            180 -> (1 - x) to (1 - y)
            270 -> y to (1 - x)
            else -> x to y
        }
    }
}
