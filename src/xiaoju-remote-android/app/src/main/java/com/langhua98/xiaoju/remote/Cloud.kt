package com.langhua98.xiaoju.remote

import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder

data class CloudItem(val id: String, val name: String, val type: String) {
    val isFolder get() = type == "folder"
}

/**
 * 小橘云盘 agent 接口（都在 /api/agent/v1 下，Bearer xa_…）。协议和 xiaoju-remote 仓库的 AGENTS.md 一致：
 * 快路是即时信箱 /relay（长轮询），服务端太旧没有时退回文件信箱。
 */
class Cloud(base: String, private val token: String) {
    private val api = base.trimEnd('/') + "/api/agent/v1"

    private fun q(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    fun me(): String {
        val j = JSONObject(String(Net.request("GET", "$api/me", token), Charsets.UTF_8))
        return j.optString("name").ifBlank { j.optJSONObject("agent")?.optString("name").orEmpty() }.ifBlank { "已连接" }
    }

    /** 列目录；目录不存在或出错时返回空。 */
    fun list(path: String): List<CloudItem> {
        val out = ArrayList<CloudItem>()
        var cursor: String? = null
        try {
            do {
                var url = "$api/items?path=${q(path)}&limit=1000"
                cursor?.let { url += "&cursor=${q(it)}" }
                val j = JSONObject(String(Net.request("GET", url, token), Charsets.UTF_8))
                val arr = j.optJSONArray("children")
                if (arr != null) for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    out.add(CloudItem(o.optString("id"), o.optString("name"), o.optString("type")))
                }
                cursor = j.optString("next_cursor").ifBlank { null }.takeIf { it != "null" }
            } while (cursor != null)
        } catch (e: Exception) { /* 当空 */ }
        return out
    }

    fun download(id: String): ByteArray = Net.request("GET", "$api/items/$id/content", token)

    /** 上传。PUT /api/agent/v1/files?path=（不是根路径的 /files）。 */
    fun upload(path: String, data: ByteArray, contentType: String = "application/octet-stream") {
        Net.request("PUT", "$api/files?path=${q(path)}", token, data, contentType)
    }

    // ---- 即时信箱 ----

    /** 取走信箱里所有消息；没有就最多等 seconds 秒。 */
    fun relayWait(box: String, seconds: Int = 25): List<JSONObject> {
        val data = Net.request("GET", "$api/relay?box=${q(box)}&wait=$seconds", token,
            readTimeoutMs = (seconds + 20) * 1000)
        val arr = JSONObject(String(data, Charsets.UTF_8)).optJSONArray("messages") ?: JSONArray()
        val out = ArrayList<JSONObject>()
        for (i in 0 until arr.length()) arr.optJSONObject(i)?.optJSONObject("body")?.let { out.add(it) }
        return out
    }

    fun relaySend(box: String, obj: JSONObject) {
        Net.request("POST", "$api/relay?box=${q(box)}", token,
            obj.toString().toByteArray(Charsets.UTF_8), "application/json")
    }

    companion object {
        /** 服务端还没有即时信箱时是 404 / 405 / 501 */
        fun relayMissing(e: Exception) = e is HttpError && e.code in setOf(404, 405, 501)
    }
}

/** 信箱名，要和控制端、scripts/遥控.py 一致。 */
object RemoteBox {
    fun inbox(dev: String) = "遥控/$dev/收件"
    fun receipt(dev: String, id: String) = "遥控/$dev/回执/$id"
    /** 回执里直接带的文件上限（base64 后要小于服务端单条 8 MB） */
    const val INLINE_LIMIT = 5 shl 20
}
