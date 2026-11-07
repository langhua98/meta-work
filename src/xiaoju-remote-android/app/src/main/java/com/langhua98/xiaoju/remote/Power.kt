package com.langhua98.xiaoju.remote

import android.content.Context
import android.os.Build
import android.os.PowerManager
import java.io.File

/**
 * 电源管家：谁要 CPU 醒着，谁就 hold 一下，做完放掉；没人要的时候 CPU 可以睡。
 *
 * 以前待命时一直拿着 WakeLock，CPU 从来不睡。现在：
 * - 相机开着（侦测、直播）、在执行指令、在备份录像、在发提醒时才拿着（各拿各的，计数）；
 * - 收指令的长轮询在等服务器回话时放掉（sleepWhile）：服务器回话的数据一到，Wi-Fi / 基带会把 CPU 叫醒，
 *   读完马上又拿上。万一卡住，RemoteService 里有 2 分钟一次的闹钟看门狗把连接断掉重来。
 * - Android 6（API 23）以上有 Doze，睡着以后网络和闹钟都会被推迟，所以那上面还是一直拿着（行为和以前一样）。
 */
object Power {
    private var wl: PowerManager.WakeLock? = null
    private var holds = 0

    /** 这台手机上等网络时能不能让 CPU 睡（没有 Doze 的老系统） */
    val canSleep: Boolean get() = Build.VERSION.SDK_INT < 23

    @Synchronized fun init(ctx: Context) {
        if (wl != null) return
        wl = (ctx.applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "xiaoju:power").apply { setReferenceCounted(false) }
    }

    @Synchronized fun acquire() {
        holds++
        if (holds == 1) runCatching { wl?.acquire() }
    }

    @Synchronized fun release() {
        if (holds <= 0) return
        holds--
        if (holds == 0) runCatching { if (wl?.isHeld == true) wl?.release() }
    }

    /** 现在有几个在要 CPU 醒着（给 info 看） */
    val holders: Int @Synchronized get() = holds

    /** 做 block 的时候 CPU 一定醒着。 */
    inline fun <T> hold(block: () -> T): T {
        acquire()
        try { return block() } finally { release() }
    }

    private val timer = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "power").apply { isDaemon = true }
    }

    /**
     * 调用方本来拿着一份：block（阻塞在网络上等回话）开始 delayMs 以后放掉，好让 CPU 睡；回来马上拿上。
     * 晚一点放：请求要先发出去（连接、写请求），发出去之前睡着了就要等看门狗来救。
     */
    fun <T> sleepWhile(delayMs: Long = 1_500, block: () -> T): T {
        if (!canSleep) return block()
        val state = java.util.concurrent.atomic.AtomicInteger(0)   // 0 = 还拿着，1 = 已经放了，2 = block 已经回来
        val task = timer.schedule(Runnable { if (state.compareAndSet(0, 1)) release() }, delayMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        try {
            return block()
        } finally {
            if (!state.compareAndSet(0, 2)) acquire()   // 已经放了：拿回来
            task.cancel(false)
        }
    }
}

/**
 * 读电池的实时电流（底层：/sys/class/power_supply，三星等很多老手机都给普通 App 读）。
 * 用来看省电到底省了多少：守望、录像、只待命各是多少毫安。读不到返回 null。
 */
object PowerMeter {
    private val FILES = listOf(
        "/sys/class/power_supply/battery/current_now",
        "/sys/class/power_supply/battery/batt_current_now",
        "/sys/class/power_supply/battery/current_avg",
        "/sys/class/power_supply/Battery/current_now",
        "/sys/class/power_supply/bms/current_now",
    )
    @Volatile private var file: File? = null
    @Volatile private var tried = false

    /** 原始数值 → 毫安（绝对值）。有的手机写毫安，有的写微安（数很大）。 */
    fun toMa(raw: String): Int? {
        val v = raw.trim().toLongOrNull() ?: return null
        val a = Math.abs(v)
        return (if (a > 20_000) a / 1000 else a).toInt()
    }

    /** 采 samples 次（隔 gapMs）取平均，毫安。 */
    fun currentMa(samples: Int = 5, gapMs: Long = 200): Int? {
        val f = pick() ?: return null
        var sum = 0L
        var n = 0
        repeat(samples.coerceAtLeast(1)) { i ->
            runCatching { toMa(f.readText()) }.getOrNull()?.let { sum += it; n++ }
            if (i < samples - 1) try { Thread.sleep(gapMs) } catch (e: InterruptedException) { return@repeat }
        }
        return if (n == 0) null else (sum / n).toInt()
    }

    private fun pick(): File? {
        if (tried) return file
        tried = true
        file = FILES.map { File(it) }.firstOrNull { f -> runCatching { f.canRead() && toMa(f.readText()) != null }.getOrDefault(false) }
        return file
    }
}
