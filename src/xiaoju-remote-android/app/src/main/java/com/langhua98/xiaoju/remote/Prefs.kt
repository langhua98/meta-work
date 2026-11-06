package com.langhua98.xiaoju.remote

import android.content.Context

/** 设置存在 App 私有的 SharedPreferences 里，别的 App 读不到。 */
class Prefs(ctx: Context) {
    private val sp = ctx.getSharedPreferences("xiaoju-remote", Context.MODE_PRIVATE)

    var base: String
        get() = sp.getString("base", "")!!.ifBlank { DEFAULT_BASE }
        set(v) { sp.edit().putString("base", v.trim().trimEnd('/')).apply() }

    var token: String
        get() = sp.getString("token", "")!!
        set(v) { sp.edit().putString("token", v.trim()).apply() }

    var device: String
        get() = sp.getString("device", "")!!.ifBlank { android.os.Build.MODEL }
        set(v) { sp.edit().putString("device", v.trim()).apply() }

    var pair: String
        get() = sp.getString("pair", "")!!
        set(v) { sp.edit().putString("pair", v.trim()).apply() }

    /** 处理过的文件信箱指令 id（避免重复执行），最多记 500 条 */
    fun isSeen(id: String) = seen().contains(id)
    fun markSeen(id: String) {
        val list = seen().toMutableList().apply { add(id) }
        sp.edit().putString("seen", list.takeLast(500).joinToString("\n")).apply()
    }
    private fun seen(): List<String> = sp.getString("seen", "")!!.split("\n").filter { it.isNotBlank() }

    companion object {
        const val DEFAULT_BASE = "https://langhua1998-xiaoju-cloud.hf.space"
    }
}
