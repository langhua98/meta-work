package com.langhua98.xiaoju.remote

import android.content.Context
import org.conscrypt.Conscrypt
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyStore
import java.security.cert.CertificateFactory
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

class HttpError(val code: Int, msg: String) : Exception(msg)

/**
 * 联网。Android 4.2 自带的 TLS 和根证书都太旧，连不上现在的 HTTPS：
 * 用 Conscrypt 做 TLS，信任「系统根证书 + App 自带的 res/raw/roots.pem」。
 */
object Net {
    @Volatile private var factory: SSLSocketFactory? = null
    @Volatile private var trust: X509TrustManager? = null
    @Volatile private var ok: okhttp3.OkHttpClient? = null

    fun init(ctx: Context) {
        if (factory != null) return
        val provider = Conscrypt.newProvider()
        val ks = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null, null) }
        // 系统自带的根证书
        runCatching {
            val sys = KeyStore.getInstance("AndroidCAStore").apply { load(null, null) }
            for (alias in sys.aliases()) sys.getCertificate(alias)?.let { ks.setCertificateEntry("sys-$alias", it) }
        }
        // App 自带的根证书
        val cf = CertificateFactory.getInstance("X.509")
        ctx.resources.openRawResource(R.raw.roots).use { input ->
            cf.generateCertificates(input).forEachIndexed { i, c -> ks.setCertificateEntry("app-$i", c) }
        }
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(ks) }
        val tm = tmf.trustManagers.first { it is X509TrustManager } as X509TrustManager
        val ssl = SSLContext.getInstance("TLS", provider)
        ssl.init(null, arrayOf(tm), null)
        trust = tm
        factory = ssl.socketFactory
    }

    /**
     * 直播用的 WebSocket 客户端（OkHttp 3.12，支持 Android 2.3+），TLS 同样走 Conscrypt + 自带根证书。
     * 读超时关掉（长连接可能很久没消息），靠每 20 秒一次心跳发现断线。
     */
    @Synchronized fun okHttp(): okhttp3.OkHttpClient {
        ok?.let { return it }
        val f = factory ?: throw IllegalStateException("Net 还没初始化")
        val c = okhttp3.OkHttpClient.Builder()
            .sslSocketFactory(f, trust!!)
            .connectTimeout(20, java.util.concurrent.TimeUnit.SECONDS)
            .writeTimeout(20, java.util.concurrent.TimeUnit.SECONDS)
            .readTimeout(0, java.util.concurrent.TimeUnit.MILLISECONDS)
            .pingInterval(20, java.util.concurrent.TimeUnit.SECONDS)
            .build()
        ok = c
        return c
    }

    /** 发一个请求，返回响应体。非 2xx 抛 HttpError。 */
    fun request(method: String, url: String, token: String, body: ByteArray? = null,
                contentType: String? = null, readTimeoutMs: Int = 60_000): ByteArray {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            if (conn is HttpsURLConnection) factory?.let { conn.sslSocketFactory = it }
            conn.requestMethod = method
            conn.connectTimeout = 20_000
            conn.readTimeout = readTimeoutMs
            conn.useCaches = false
            conn.setRequestProperty("Authorization", "Bearer $token")
            conn.setRequestProperty("Accept", "application/json")
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", contentType ?: "application/octet-stream")
                conn.setFixedLengthStreamingMode(body.size)
                conn.outputStream.use { it.write(body) }
            }
            val code = conn.responseCode
            val stream: InputStream? = if (code in 200..299) conn.inputStream else conn.errorStream
            val data = stream?.use { readAll(it) } ?: ByteArray(0)
            if (code !in 200..299) {
                val msg = runCatching { org.json.JSONObject(String(data, Charsets.UTF_8)) }.getOrNull()
                    ?.let { it.optString("message").ifBlank { it.optString("error") } }.orEmpty()
                throw HttpError(code, "云盘 $code" + if (msg.isBlank()) "" else "：$msg")
            }
            return data
        } finally {
            conn.disconnect()
        }
    }

    private fun readAll(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }
}
