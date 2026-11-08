package com.langhua98.xiaoju.remote

import org.json.JSONObject

/**
 * 直播中可以随时调的设置（观看端发 video_set 指令改）。
 * - 前后镜头、清晰度、编码（h264 / jpeg）：要关掉相机重开（version 加 1），直播连接不断；
 * - 画质、帧率：每一帧都重新读；
 * - 亮度（曝光补偿）、变焦、手电：在正开着的相机上设一下（tweak 加 1）；
 * - 守望（省电侦测、没动静时）：传感器换到最低帧率档、每秒只要 WATCH_FPS 帧（profile 加 1，不重开相机）。
 */
class LiveSettings(front: Boolean, width: Int, quality: Int, fps: Int, codec: String = JPEG) {
    @Volatile var front = front; private set
    /** h264 = 硬件 H.264（省流量、更流畅）；jpeg = 一帧一张 JPEG（兼容，老查看器只认这个） */
    @Volatile var codec = if (codec == H264) H264 else JPEG; private set
    @Volatile var width = width.coerceIn(240, 1280); private set
    @Volatile var quality = quality.coerceIn(20, 90)
    @Volatile var fps = fps.coerceIn(1, 15)
    @Volatile var exposure = 0f    // -1…1，0 = 自动
    @Volatile var zoom = 0f        // 0…1
    @Volatile var torch = false
    /** 上下翻转（画面转 180°，手机倒着装时用）：直播、录像、截图都跟着转，记在手机上 */
    @Volatile var flip = false
    /** 画面左上角印日期时间（直播、录像、截图都带上） */
    @Volatile var stamp = true
    @Volatile var version = 0; private set
    @Volatile var tweak = 0; private set
    /** 省电侦测「守望」中（没动静）：相机能多慢就多慢 */
    @Volatile var watch = false; private set
    @Volatile var profile = 0; private set
    /** 现在每秒要几帧（守望时只要 WATCH_FPS 帧，相机驱动里多出来的帧不拷给我们） */
    val frameFps: Int get() = if (watch) WATCH_FPS else fps
    /** 最近一次在相机上设参数时，这台手机不支持的项（给回执用） */
    @Volatile var unsupported = ""
    /** 硬件 H.264 用不了、退回 JPEG 的原因（给回执用） */
    @Volatile var codecNote = ""

    /** 按指令里出现的字段改，返回改了哪些（中文，给回执用） */
    fun apply(cmd: JSONObject): List<String> {
        val changed = ArrayList<String>()
        if (cmd.has("lens")) {
            val f = cmd.optString("lens") == "front"
            if (f != front) { front = f; version++; changed += if (f) "前置镜头" else "后置镜头" }
        }
        if (cmd.has("codec")) {
            val c = if (cmd.optString("codec") == H264) H264 else JPEG
            if (c != codec) { codec = c; version++; changed += if (c == H264) "H.264 编码" else "JPEG 兼容模式" }
        }
        if (cmd.has("width")) {
            val w = cmd.optInt("width", width).coerceIn(240, 1280)
            if (w != width) { width = w; version++; changed += "清晰度 $w" }
        }
        if (cmd.has("quality")) { quality = cmd.optInt("quality", quality).coerceIn(20, 90); changed += "画质 $quality" }
        if (cmd.has("fps")) { fps = cmd.optInt("fps", fps).coerceIn(1, 15); changed += "帧率 $fps" }
        if (cmd.has("flip")) {
            val f = cmd.optBoolean("flip", flip)
            if (f != flip) { flip = f; changed += if (f) "画面上下翻转" else "画面不翻转" }
        }
        if (cmd.has("stamp")) {
            val st = cmd.optBoolean("stamp", stamp)
            if (st != stamp) { stamp = st; changed += if (st) "印日期时间" else "不印日期时间" }
        }
        var t = false
        if (cmd.has("exposure")) { exposure = cmd.optDouble("exposure", 0.0).toFloat().coerceIn(-1f, 1f); t = true; changed += "亮度" }
        if (cmd.has("zoom")) { zoom = cmd.optDouble("zoom", 0.0).toFloat().coerceIn(0f, 1f); t = true; changed += "变焦" }
        if (cmd.has("torch")) { torch = cmd.optBoolean("torch", false); t = true; changed += if (torch) "手电开" else "手电关" }
        if (t) tweak++
        return changed
    }

    /** 进 / 出「守望」（变了才加 profile，相机在开着的时候换帧率档）。 */
    fun setWatch(on: Boolean) { if (on != watch) { watch = on; profile++ } }

    /** 硬件 H.264 不行（没有编码器、出错、不出数据）时退回 JPEG，不重开相机。 */
    fun fallbackToJpeg() { codec = JPEG }

    companion object {
        const val H264 = "h264"
        const val JPEG = "jpeg"
        /** 守望时每秒看几帧（移动侦测连着两次看到变化才算，4 帧/秒时大约半秒就能发现） */
        const val WATCH_FPS = 4

        /**
         * 选预览帧率范围（相机给的 [最低, 最高]，单位 1/1000 帧/秒）。相机传感器跑得越快越费电，
         * 所以只选「够用」的最低一档：
         * - 平时（录像、直播，最多 15 帧/秒）：最高帧率够 max(15, fps) 的档里最高帧率最低的；
         *   其中选最低帧率不低于 15 的（暗的时候也不掉到 15 以下，一动就糊），没有就选最低帧率最高的。
         *   以前选的是最高那档（常常是 30 帧/秒），一半的帧根本用不上。
         * - 守望（watch）：最高帧率够 fps 的档里最高、最低帧率都尽量低（暗的时候曝光长一点也不要紧，只是看有没有动静）。
         * 没有够用的档就选最高的。
         */
        fun pickFpsRange(ranges: List<IntArray>, fps: Int = 15, watch: Boolean = false): IntArray? {
            if (ranges.isEmpty()) return null
            val need = (if (watch) fps.coerceAtLeast(1) else maxOf(15, fps)) * 1000
            val ok = ranges.filter { it[1] >= need }
            if (ok.isEmpty()) {
                val top = ranges.maxOf { it[1] }
                return ranges.filter { it[1] == top }.maxByOrNull { it[0] }
            }
            val low = ok.minOf { it[1] }
            val c = ok.filter { it[1] == low }
            return if (watch) c.minByOrNull { it[0] }
            else c.filter { it[0] >= 15_000 }.minByOrNull { it[0] } ?: c.maxByOrNull { it[0] }
        }

        /**
         * 选预览尺寸（sizes 是相机支持的 宽 to 高）。JPEG：宽度不小于 target 里最小的，没有就最大的。
         * H.264：先在硬件编码器肯定能吃的尺寸里这么选（见 H264.sizeOk），一个都没有再按 JPEG 的选。
         */
        fun pickSize(sizes: List<Pair<Int, Int>>, target: Int, h264: Boolean): Pair<Int, Int>? {
            fun pick(c: List<Pair<Int, Int>>) =
                c.filter { it.first >= target }.minByOrNull { it.first } ?: c.maxByOrNull { it.first }
            if (h264) sizes.filter { com.langhua98.xiaoju.remote.H264.sizeOk(it.first, it.second) }.takeIf { it.isNotEmpty() }?.let { return pick(it) }
            return pick(sizes)
        }

        /** -1…1 映射到相机的曝光补偿档位 [min, max] */
        fun exposureIndex(v: Float, min: Int, max: Int): Int =
            if (v >= 0) Math.round(v * max) else Math.round(-v * min)
    }
}
