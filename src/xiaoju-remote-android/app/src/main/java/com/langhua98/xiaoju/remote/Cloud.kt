package com.langhua98.xiaoju.remote

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class CloudError(msg: String) : Exception(msg)

data class CloudItem(val id: String, val name: String, val type: String, val size: Long, val sha256: String?) {
    val isFolder get() = type == "folder"
}

/** 小橘云盘 agent 接口客户端（/api/agent/v1，Bearer xa_…）。 */
class Cloud(private val base: String, private val token: String) {

    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .build()

    private fun bytes(req: Request): ByteArray {
        http.newCall(req).execute().use { r ->
            val body = r.body?.bytes() ?: ByteArray(0)
            if (!r.isSuccessful) {
                val msg = runCatching { JSONObject(String(body)).optString("message") }.getOrNull()
                throw CloudError("云盘 ${r.code}${if (msg.isNullOrBlank()) "" else "：$msg"}")
            }
            return body
        }
    }

    private fun get(path: String, query: Map<String, String> = emptyMap()): ByteArray {
        val url = (base + path).toHttpUrl().newBuilder()
            .apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }
            .build()
        return bytes(Request.Builder().url(url).header("Authorization", "Bearer $token").get().build())
    }

    fun me(): String {
        val j = JSONObject(String(get("/api/agent/v1/me")))
        return j.optJSONObject("agent")?.optString("name") ?: "已连接"
    }

    fun list(path: String): List<CloudItem> {
        val out = ArrayList<CloudItem>()
        var cursor: String? = null
        do {
            val q = hashMapOf("path" to path, "limit" to "1000")
            cursor?.let { q["cursor"] = it }
            val j = JSONObject(String(get("/api/agent/v1/items", q)))
            // 路径不存在时云盘会报错，调用方当作空处理
            val arr = j.optJSONArray("children")
            if (arr != null) for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                out.add(CloudItem(o.optString("id"), o.optString("name"), o.optString("type"),
                    o.optLong("size"), o.optString("sha256").ifBlank { null }))
            }
            // 最后一页云盘回 next_cursor: null；optString 会把 null 读成字符串 "null"，导致死循环，所以要先判 isNull
            cursor = if (j.isNull("next_cursor")) null else j.optString("next_cursor").ifBlank { null }
        } while (cursor != null)
        return out
    }

    /** 列目录，目录不存在时返回空而不是抛错。 */
    fun listOrEmpty(path: String): List<CloudItem> = runCatching { list(path) }.getOrDefault(emptyList())

    fun download(id: String): ByteArray = get("/api/agent/v1/items/$id/content")

    /** 上传。PUT /api/agent/v1/files?path=/… ，原始字节（同名不覆盖，云盘会改名“名字 (2)”）。 */
    fun upload(path: String, data: ByteArray, contentType: String = "application/octet-stream") {
        val url = (base + "/api/agent/v1/files").toHttpUrl().newBuilder()
            .addQueryParameter("path", path).build()
        val req = Request.Builder().url(url)
            .header("Authorization", "Bearer $token")
            .put(data.toRequestBody(contentType.toMediaTypeOrNull()))
            .build()
        bytes(req)
    }

    fun uploadText(path: String, text: String) =
        upload(path, text.toByteArray(Charsets.UTF_8), "application/json; charset=utf-8")
}
