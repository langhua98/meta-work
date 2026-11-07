package com.langhua98.xiaoju.remote

import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 一次「有动静」录下来的一段。name 是文件名（不带扩展名），也是 iPhone 那边取视频时用的名字。 */
class EventInfo(
    val name: String,
    val at: Long,                 // 开始时间（墙上时间，毫秒）
    var durMs: Long = 0,
    var motions: Int = 1,         // 这段里检测到几次动静
    var video: Boolean = false,   // 有没有视频（硬件编码用不了时只有截图）
    var uploaded: String = "",    // 备份到云盘的路径，空 = 还没备份
) {
    /** 认出来在动的是什么（「人×2、猫」），没认出来是空 */
    @Volatile var labels: String = ""

    fun toJson(): JSONObject = JSONObject().put("name", name).put("at", at).put("dur", durMs)
        .put("motions", motions).put("video", video).put("uploaded", uploaded).put("labels", labels)

    companion object {
        fun fromJson(j: JSONObject) = EventInfo(j.getString("name"), j.optLong("at"), j.optLong("dur"),
            j.optInt("motions", 1), j.optBoolean("video"), j.optString("uploaded")).also { it.labels = j.optString("labels") }
    }
}

/**
 * 录像存在手机本地（dir 下：<名字>.mov 视频、.jpg 截图、.t.jpg 小图、.json 信息），满了删最旧的。
 * 只有写完（有 .json）的才算一段，正在录的不会被列出来、删掉、上传。不碰安卓的类，可以在电脑上跑测试。
 */
class EventStore(val dir: File, var maxBytes: Long = 3L shl 30, var minFreeBytes: Long = 500L shl 20) {
    init { dir.mkdirs() }

    fun mov(name: String) = File(dir, "$name.mov")
    fun jpg(name: String) = File(dir, "$name.jpg")
    fun thumb(name: String) = File(dir, "$name.t.jpg")
    private fun meta(name: String) = File(dir, "$name.json")

    /** 按开始时间起名（20261107-153012），同一秒有了就加 -2、-3。 */
    @Synchronized fun newName(at: Long): String {
        val base = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date(at))
        var n = base
        var k = 2
        while (mov(n).exists() || meta(n).exists() || jpg(n).exists()) n = "$base-${k++}"
        return n
    }

    @Synchronized fun save(e: EventInfo) {
        val tmp = File(dir, "${e.name}.json.tmp")
        tmp.writeText(e.toJson().toString())
        tmp.renameTo(meta(e.name))
    }

    @Synchronized fun get(name: String): EventInfo? = try {
        if (!safe(name)) null else EventInfo.fromJson(JSONObject(meta(name).readText()))
    } catch (e: Exception) { null }

    /** 写完的所有段，新的在前。 */
    @Synchronized fun list(): List<EventInfo> =
        (dir.listFiles() ?: emptyArray()).filter { it.name.endsWith(".json") }
            .mapNotNull { get(it.name.removeSuffix(".json")) }.sortedByDescending { it.at }

    /** 等着备份的（最旧的在前）。 */
    fun pendingUpload(): List<EventInfo> = list().filter { it.video && it.uploaded.isEmpty() && mov(it.name).exists() }.reversed()

    @Synchronized fun markUploaded(name: String, path: String) {
        val e = get(name) ?: return
        e.uploaded = path
        save(e)
    }

    @Synchronized fun delete(name: String): Boolean {
        if (!safe(name)) return false
        var any = false
        for (f in listOf(mov(name), jpg(name), thumb(name), meta(name))) if (f.delete()) any = true
        return any
    }

    fun usedBytes(): Long = (dir.listFiles() ?: emptyArray()).sumOf { it.length() }

    /** 超过上限、或者手机快没空间了，从最旧的删起（先删已经备份过的）。返回删了几段。 */
    @Synchronized fun cleanup(free: () -> Long = { dir.usableSpace }): Int {
        var removed = 0
        val all = list().reversed()   // 旧的在前
        val order = all.filter { it.uploaded.isNotEmpty() } + all.filter { it.uploaded.isEmpty() }
        var used = usedBytes()
        for (e in order) {
            if (used <= maxBytes && free() >= minFreeBytes) break
            val size = listOf(mov(e.name), jpg(e.name), thumb(e.name)).sumOf { it.length() }
            if (delete(e.name)) { removed++; used -= size }
        }
        return removed
    }

    /** 名字只能是自己起的那种（防止 ../ 之类的路径）。 */
    private fun safe(name: String) = Regex("^[0-9]{8}-[0-9]{6}(-[0-9]+)?$").matches(name)
}
