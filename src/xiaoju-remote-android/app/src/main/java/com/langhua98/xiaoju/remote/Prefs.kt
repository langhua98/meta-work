package com.langhua98.xiaoju.remote

import android.content.Context

/** 设置存本地。令牌等用 EncryptedSharedPreferences 更好，这里先用普通的，App 私有目录别的 App 读不到。 */
class Prefs(ctx: Context) {
    private val sp = ctx.getSharedPreferences("xiaoju-remote", Context.MODE_PRIVATE)

    var base: String
        get() = sp.getString("base", "")!!.ifBlank { DEFAULT_BASE }
        set(v) = sp.edit().putString("base", v.trim().trimEnd('/')).apply()

    var token: String
        get() = sp.getString("token", "")!!
        set(v) = sp.edit().putString("token", v.trim()).apply()

    var device: String
        get() = sp.getString("device", "")!!.ifBlank { android.os.Build.MODEL }
        set(v) = sp.edit().putString("device", v.trim()).apply()

    var pair: String
        get() = sp.getString("pair", "")!!
        set(v) = sp.edit().putString("pair", v.trim()).apply()

    companion object {
        const val DEFAULT_BASE = "https://langhua1998-xiaoju-cloud.hf.space"
    }
}
