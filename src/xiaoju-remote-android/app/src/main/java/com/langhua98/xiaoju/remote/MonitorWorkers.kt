package com.langhua98.xiaoju.remote

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Telegram 提醒：有新的事件就发一条（带截图），两次之间至少隔 cooldown 分钟；
 * 冷却期间的事件不单独发，下一条提醒里说「这之前还有 N 次」。在自己的线程上发，不卡相机。
 */
class Notifier(private val cloud: Cloud, private val prefs: Prefs, private val device: String) {
    private val q = LinkedBlockingQueue<Pair<String, ByteArray?>>(20)
    @Volatile private var lastAt = 0L
    @Volatile private var skipped = 0
    /** 最近一次发的结果（给 monitor_status 看） */
    @Volatile var status = "还没发过"
        private set
    private val thread = Thread({ loop() }, "notify").apply { isDaemon = true; start() }

    /** 有新的事件。cooldownMin 分钟内发过就先攒着。 */
    fun event(at: Long, jpg: ByteArray?, cooldownMin: Int, labels: String = "") {
        val now = System.currentTimeMillis()
        if (now - lastAt < cooldownMin * 60_000L) { skipped++; return }
        lastAt = now
        val t = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date(at))
        val more = if (skipped > 0) "（这之前 $cooldownMin 分钟里还有 $skipped 次）" else ""
        skipped = 0
        val what = if (labels.isEmpty()) "有动静" else "有动静：$labels"
        q.offer("🍊 小橘遥控 · $device\n$t $what$more" to jpg)
    }

    /** 随便发一句（打开侦测时确认 Telegram 通不通）。 */
    fun text(s: String) { q.offer("🍊 小橘遥控 · $device\n$s" to null) }

    private fun loop() {
        while (true) {
            val (text, jpg) = try { q.take() } catch (e: InterruptedException) { return }
            try {
                val chat = cloud.notify(text, jpg, prefs.tgChat)
                if (chat != 0L && chat != prefs.tgChat) prefs.tgChat = chat
                status = "已发到 Telegram（${SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())}）"
            } catch (e: HttpError) {
                status = when (e.code) {
                    404 -> "云盘服务端还不能发 Telegram 提醒（要先更新服务端）"
                    501 -> "云盘服务端没有配置 Telegram 机器人"
                    else -> "Telegram 提醒没发出去：${e.message}"
                }
                Bus.push(status)
            } catch (e: Exception) {
                status = "Telegram 提醒没发出去：${e.message ?: e.javaClass.simpleName}"
                Bus.push(status)
            }
        }
    }
}

/**
 * 录像慢慢备份到云盘：一次传一个，传完歇 gapMs 再传下一个，限速 bps；有人在看实时画面时不传（不抢网速）。
 * 云盘存储后面是 Telegram，传太快会被限流，所以宁可慢。路径 /小橘推送/遥控/<设备>/录像/<日期>/<时间>.mov。
 */
class Uploader(
    private val cloud: Cloud, private val store: EventStore, private val device: String,
    private val enabled: () -> Boolean, private val busy: () -> Boolean,
) {
    @Volatile var status = ""
        private set
    @Volatile private var stop = false
    private val wake = Object()
    private val thread = Thread({ loop() }, "backup").apply { isDaemon = true; start() }

    fun close() { stop = true; synchronized(wake) { wake.notifyAll() } }

    /** 云盘上的路径。 */
    fun pathFor(e: EventInfo): String =
        "/小橘推送/遥控/$device/录像/${SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(e.at))}/${e.name}.mov"

    /** 现在就传这一段（iPhone 要看一段还没备份的大视频时），返回云盘路径。 */
    fun uploadNow(e: EventInfo): String {
        val p = pathFor(e)
        cloud.uploadSlow(p, store.mov(e.name).readBytes(), FAST_BPS)
        store.markUploaded(e.name, p)
        return p
    }

    private fun loop() {
        var backoff = 0L
        var lastDone = 0L
        var today = ""
        var count = 0
        while (!stop) {
            synchronized(wake) { try { wake.wait(if (backoff > 0) backoff else 20_000L) } catch (e: InterruptedException) { return } }
            backoff = 0
            if (stop) return
            if (!enabled() || busy()) continue
            if (System.currentTimeMillis() - lastDone < GAP_MS) continue
            val day = SimpleDateFormat("yyyyMMdd", Locale.US).format(Date())
            if (day != today) { today = day; count = 0 }
            if (count >= DAILY_MAX) { status = "今天已经备份了 $count 段，明天接着传"; continue }
            val e = store.pendingUpload().firstOrNull() ?: continue
            val f = store.mov(e.name)
            if (!f.exists()) continue
            try {
                val p = pathFor(e)
                cloud.uploadSlow(p, f.readBytes(), SLOW_BPS)
                store.markUploaded(e.name, p)
                count++
                val left = store.pendingUpload().size
                status = "已备份 ${e.name}" + if (left > 0) "，还有 $left 段等着" else ""
                Bus.push(status)
            } catch (ex: Exception) {
                status = "备份出错，5 分钟后再试：${ex.message}"
                Bus.push(status)
                backoff = 5 * 60_000L
            }
            lastDone = System.currentTimeMillis()
        }
    }

    companion object {
        const val SLOW_BPS = 128 * 1024        // 平时备份：128 KB/s
        const val FAST_BPS = 512 * 1024        // iPhone 等着看：快一点
        const val GAP_MS = 60_000L             // 两个文件之间歇 1 分钟
        const val DAILY_MAX = 500
    }
}
