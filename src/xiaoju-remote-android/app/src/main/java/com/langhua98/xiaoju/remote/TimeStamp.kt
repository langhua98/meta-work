package com.langhua98.xiaoju.remote

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 在画面左上角印日期时间（直接改相机 NV21 的亮度），直播、录像、截图都带上。
 *
 * 文字每秒才变一次：每秒用安卓画一次字（白字黑边），算好每个像素落在原始画面的哪个位置、多亮、多不透明；
 * 每一帧只按这张表改几千个字节，老手机也不费劲。字那一块的颜色（UV）设成灰，不然字会被底下的颜色染绿染红。
 *
 * 相机画面是「没转正」的，看的一端要顺时针转 rot 度才正（rot 里已经算上了上下翻转）。
 * 所以字要按转正以后的左上角来放，再反过来算回原始画面上的位置（toRaw），转正以后字就是正的。
 */
class TimeStamp {
    private val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
    private var lastText = ""
    private var lastKey = ""
    private var idx = IntArray(0)      // 原始画面里的亮度下标
    private var lum = IntArray(0)      // 字在这里的亮度
    private var alpha = IntArray(0)    // 字在这里的不透明度 0…255
    private var uv = IntArray(0)       // 要去掉颜色的 UV 下标

    fun draw(nv21: ByteArray, w: Int, h: Int, rot: Int) {
        if (nv21.size < w * h * 3 / 2) return
        val text = fmt.format(Date())
        val key = "$w×$h/$rot"
        if (text != lastText || key != lastKey) {
            try { build(text, w, h, rot) } catch (e: Throwable) { idx = IntArray(0); uv = IntArray(0) }
            lastText = text; lastKey = key
        }
        for (i in idx.indices) {
            val p = idx[i]
            val a = alpha[i]
            val y = nv21[p].toInt() and 0xff
            nv21[p] = ((y * (255 - a) + lum[i] * a) / 255).toByte()
        }
        for (p in uv) nv21[p] = 128.toByte()
    }

    private fun build(text: String, w: Int, h: Int, rot: Int) {
        val r = (rot % 360 + 360) % 360
        val uw = if (r == 90 || r == 270) h else w            // 转正以后的宽
        val size = maxOf(12f, uw / 30f)                         // 640 宽 → 21 像素高的字
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFFFFFFF.toInt(); textSize = size; typeface = Typeface.MONOSPACE
        }
        val stroke = Paint(fill).apply {
            color = 0xFF000000.toInt(); style = Paint.Style.STROKE; strokeWidth = maxOf(2f, size / 7)
        }
        val pad = (size / 4).toInt() + 2
        val bw = fill.measureText(text).toInt() + pad * 2
        val fm = fill.fontMetricsInt
        val bh = (fm.descent - fm.ascent) + pad * 2
        val bmp = Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val baseline = (pad - fm.ascent).toFloat()
        c.drawText(text, pad.toFloat(), baseline, stroke)
        c.drawText(text, pad.toFloat(), baseline, fill)
        val px = IntArray(bw * bh)
        bmp.getPixels(px, 0, bw, 0, 0, bw, bh)
        bmp.recycle()

        val margin = (size / 2).toInt()
        val ix = ArrayList<Int>(); val lm = ArrayList<Int>(); val al = ArrayList<Int>()
        val uvSet = LinkedHashSet<Int>()
        for (j in 0 until bh) for (i in 0 until bw) {
            val argb = px[j * bw + i]
            val a = argb ushr 24
            if (a == 0) continue
            val raw = toRaw(margin + i, margin + j, w, h, r) ?: continue
            val (x, y) = raw
            val rr = (argb shr 16) and 0xff; val gg = (argb shr 8) and 0xff; val b = argb and 0xff
            ix += y * w + x
            lm += (rr * 299 + gg * 587 + b * 114) / 1000
            al += a
            val v = w * h + (y / 2) * w + (x / 2) * 2   // NV21：先 V 后 U
            uvSet += v; uvSet += v + 1
        }
        idx = ix.toIntArray(); lum = lm.toIntArray(); alpha = al.toIntArray(); uv = uvSet.toIntArray()
    }

    companion object {
        /**
         * 转正以后的像素 (u, v) → 原始画面 (w×h) 上的像素；出界返回 null。
         * 转正 = 顺时针转 rot：90° 时 u = h-1-y、v = x（和 MotionDetector.upright 一致），这里反过来算。
         */
        fun toRaw(u: Int, v: Int, w: Int, h: Int, rot: Int): Pair<Int, Int>? {
            val (x, y) = when ((rot % 360 + 360) % 360) {
                90 -> v to (h - 1 - u)
                180 -> (w - 1 - u) to (h - 1 - v)
                270 -> (w - 1 - v) to u
                else -> u to v
            }
            return if (x in 0 until w && y in 0 until h) x to y else null
        }
    }
}
