package com.langhua98.xiaoju.remote

import org.json.JSONObject

/**
 * 直播中可以随时调的设置（观看端发 video_set 指令改）。
 * - 前后镜头、清晰度：要关掉相机重开（version 加 1），直播连接不断；
 * - 画质、帧率：每一帧都重新读；
 * - 亮度（曝光补偿）、变焦、手电：在正开着的相机上设一下（tweak 加 1）。
 */
class LiveSettings(front: Boolean, width: Int, quality: Int, fps: Int) {
    @Volatile var front = front; private set
    @Volatile var width = width.coerceIn(240, 1280); private set
    @Volatile var quality = quality.coerceIn(20, 90)
    @Volatile var fps = fps.coerceIn(1, 15)
    @Volatile var exposure = 0f    // -1…1，0 = 自动
    @Volatile var zoom = 0f        // 0…1
    @Volatile var torch = false
    @Volatile var version = 0; private set
    @Volatile var tweak = 0; private set
    /** 最近一次在相机上设参数时，这台手机不支持的项（给回执用） */
    @Volatile var unsupported = ""

    /** 按指令里出现的字段改，返回改了哪些（中文，给回执用） */
    fun apply(cmd: JSONObject): List<String> {
        val changed = ArrayList<String>()
        if (cmd.has("lens")) {
            val f = cmd.optString("lens") == "front"
            if (f != front) { front = f; version++; changed += if (f) "前置镜头" else "后置镜头" }
        }
        if (cmd.has("width")) {
            val w = cmd.optInt("width", width).coerceIn(240, 1280)
            if (w != width) { width = w; version++; changed += "清晰度 $w" }
        }
        if (cmd.has("quality")) { quality = cmd.optInt("quality", quality).coerceIn(20, 90); changed += "画质 $quality" }
        if (cmd.has("fps")) { fps = cmd.optInt("fps", fps).coerceIn(1, 15); changed += "帧率 $fps" }
        var t = false
        if (cmd.has("exposure")) { exposure = cmd.optDouble("exposure", 0.0).toFloat().coerceIn(-1f, 1f); t = true; changed += "亮度" }
        if (cmd.has("zoom")) { zoom = cmd.optDouble("zoom", 0.0).toFloat().coerceIn(0f, 1f); t = true; changed += "变焦" }
        if (cmd.has("torch")) { torch = cmd.optBoolean("torch", false); t = true; changed += if (torch) "手电开" else "手电关" }
        if (t) tweak++
        return changed
    }

    companion object {
        /** -1…1 映射到相机的曝光补偿档位 [min, max] */
        fun exposureIndex(v: Float, min: Int, max: Int): Int =
            if (v >= 0) Math.round(v * max) else Math.round(-v * min)
    }
}
