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

    /** 慢慢传（限速 bps 字节/秒），给录像备份用。已经有同名的文件当传过了。 */
    fun uploadSlow(path: String, data: ByteArray, bps: Int) {
        try {
            Net.request("PUT", "$api/files?path=${q(path)}", token, data, "video/quicktime", readTimeoutMs = 120_000, throttleBps = bps)
        } catch (e: HttpError) {
            if (e.code != 409) throw e
        }
    }

    /** 经服务端用 Telegram 机器人发提醒，返回发给了哪个聊天（记下来下次带上）。 */
    fun notify(text: String, jpg: ByteArray?, chat: Long): Long {
        val body = JSONObject().put("text", text)
        if (jpg != null) body.put("photo", android.util.Base64.encodeToString(jpg, android.util.Base64.NO_WRAP))
        if (chat != 0L) body.put("chat", chat)
        val r = Net.request("POST", "$api/notify", token, body.toString().toByteArray(Charsets.UTF_8), "application/json")
        return JSONObject(String(r, Charsets.UTF_8)).optLong("chat", chat)
    }

    /** 上传。PUT /api/agent/v1/files?path=（不是根路径的 /files）。 */
    fun upload(path: String, data: ByteArray, contentType: String = "application/octet-stream") {
        Net.request("PUT", "$api/files?path=${q(path)}", token, data, contentType)
    }

    // ---- 即时信箱 ----

    /** 取走信箱里所有消息；没有就最多等 seconds 秒。 */
    @Volatile private var pollConn: java.net.HttpURLConnection? = null

    /** 把正在等的长轮询断掉（看门狗发现它卡住了：手机睡着时连接断了没收到）。 */
    fun abortPoll() { runCatching { pollConn?.disconnect() } }

    fun relayWait(box: String, seconds: Int = 25): List<JSONObject> {
        val data = Net.request("GET", "$api/relay?box=${q(box)}&wait=$seconds", token,
            readTimeoutMs = (seconds + 20) * 1000, onConn = { pollConn = it }, reuse = true)
        val arr = JSONObject(String(data, Charsets.UTF_8)).optJSONArray("messages") ?: JSONArray()
        val out = ArrayList<JSONObject>()
        for (i in 0 until arr.length()) arr.optJSONObject(i)?.optJSONObject("body")?.let { out.add(it) }
        return out
    }

    /** 发一条到即时信箱（回执就是这么发的）。云盘一时忙不过来（429、502、503、504）或网络断了一下，隔一会儿再试，最多 3 次：
     *  回执丢了的话，看的一端只能干等到超时。 */
    fun relaySend(box: String, obj: JSONObject) {
        val body = obj.toString().toByteArray(Charsets.UTF_8)
        var wait = 1_500L
        for (attempt in 1..3) {
            try {
                Net.request("POST", "$api/relay?box=${q(box)}", token, body, "application/json")
                return
            } catch (e: Exception) {
                val retry = (e is HttpError && e.code in setOf(429, 502, 503, 504)) || e is java.io.IOException
                if (!retry || attempt == 3) throw e
                Thread.sleep(wait)
                wait *= 2
            }
        }
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
    /** 实时画面：被控端把一帧帧 JPEG 推到这里，控制端长轮询取最新一帧显示 */
    fun video(dev: String) = "遥控/$dev/视频"
    /** 回执里直接带的文件上限（base64 后要小于服务端单条 8 MB） */
    const val INLINE_LIMIT = 5 shl 20
}
