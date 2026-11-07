package com.langhua98.xiaoju.remote

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Process

/** C++ 那边（app/src/main/cpp/bench.cpp，用 ncnn）。安装包里没有这个库（没编 ncnn）时 available = false。 */
object NativeBench {
    val available: Boolean = try { System.loadLibrary("xjbench"); true } catch (e: Throwable) { false }

    /** 返回 [最快, 平均, 最慢, 次数]（毫秒），模型读不进来返回 null。 */
    @JvmStatic external fun run(param: String, w: Int, h: Int, threads: Int, budgetMs: Int, maxLoops: Int): FloatArray?
    @JvmStatic external fun cpuCount(): Int
}

/**
 * 模型测速：几个能认出「人」的小模型在这台手机上各跑一遍（1、2、4 个核），
 * 有人在看实时画面时再测一下「一边直播一边跑模型」直播的帧率掉了多少。
 * 在后台优先级上跑（视频线程随时能先跑），整个测完大约一分钟。
 */
class ModelBench(private val ctx: Context, private val hub: CameraHub?) {
    class Model(val name: String, val file: String, val w: Int, val h: Int)

    private val models = listOf(
        Model("YOLO-Fastest 1.1", "yolo-fastest-1.1.param", 320, 320),
        Model("YOLO-FastestV2", "yolo-fastestv2.param", 352, 352),
        Model("FastestDet", "FastestDet.param", 352, 352),
        Model("NanoDet-m", "nanodet_m.param", 320, 320),
        Model("MobileNet-SSD", "mobilenet_ssd.param", 300, 300),
        Model("MobileNet-SSD int8", "mobilenet_ssd_int8.param", 300, 300),
    )

    /** 跑完返回一段文字报告；progress 每测完一项报一次。 */
    fun run(progress: (String) -> Unit = {}): String {
        if (!NativeBench.available) return "这个安装包里没有模型推理库（编的时候没带 ncnn），测不了"
        val old = Process.getThreadPriority(Process.myTid())
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        try {
            val cores = NativeBench.cpuCount()
            val sb = StringBuilder()
            sb.append("模型测速（${Build.MODEL}，Android ${Build.VERSION.RELEASE}，$cores 核，开始时电池 ${temp()}）\n")
            sb.append("每次认一张图要多少毫秒：最快 / 平均（1 核 · 2 核 · 4 核）\n")
            val threads = listOf(1, 2, 4).filter { it <= maxOf(cores, 1) }
            for (m in models) {
                if (Thread.currentThread().isInterrupted) { sb.append("（被取消了，后面的没测）\n"); break }
                val param = try { ctx.assets.open("models/${m.file}").bufferedReader().readText() } catch (e: Exception) {
                    sb.append("${m.name}：模型文件读不了\n"); continue
                }
                val cells = threads.map { t ->
                    val r = NativeBench.run(param, m.w, m.h, t, 2_000, 10)
                    if (r == null) "出错" else "${r[0].toInt()}/${r[1].toInt()}"
                }
                val line = "${m.name}（${m.w}×${m.h}）：" + cells.joinToString(" · ")
                sb.append(line).append('\n')
                progress(line)
            }
            liveImpact(param = models[3], threads = 2)?.let { sb.append(it).append('\n') }
            sb.append("测完电池 ${temp()}")
            return sb.toString()
        } finally {
            Process.setThreadPriority(old)
        }
    }

    /** 有人在看实时画面：比一比跑模型前后，直播每秒发出几帧。 */
    private fun liveImpact(param: Model, threads: Int): String? {
        val h = hub ?: return null
        if (!h.watching()) return "（测的时候没人在看实时画面，没测「一边直播一边跑」；开着实时画面再测一次就有）"
        val text = try { ctx.assets.open("models/${param.file}").bufferedReader().readText() } catch (e: Exception) { return null }
        val before = h.framesPerSecond(3_000)
        var runs = 0
        val t = Thread({
            val end = System.currentTimeMillis() + 4_000
            while (System.currentTimeMillis() < end) {
                NativeBench.run(text, param.w, param.h, threads, 300, 3); runs++
            }
        }, "bench-live").apply {
            priority = Thread.MIN_PRIORITY
            start()
        }
        Thread.sleep(500)
        val during = h.framesPerSecond(3_000)
        t.join()
        return "一边直播一边跑 ${param.name}（$threads 核）：直播 ${"%.1f".format(before)} 帧/秒 → ${"%.1f".format(during)} 帧/秒"
    }

    private fun temp(): String {
        val i: Intent? = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val t = i?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
        return if (t < 0) "温度未知" else "${t / 10}.${t % 10}°C"
    }
}
