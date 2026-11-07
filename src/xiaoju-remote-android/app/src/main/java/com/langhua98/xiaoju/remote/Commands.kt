package com.langhua98.xiaoju.remote

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.media.MediaRecorder
import android.media.RingtoneManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.HandlerThread
import android.os.Process
import android.os.Vibrator
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class CmdResult(val text: String, val files: List<Pair<String, ByteArray>> = emptyList())

/** 一条指令 → 用本机硬件执行 → 结果。都是阻塞调用，在后台线程里跑。 */
object Commands {

    private fun has(ctx: Context, perm: String) =
        ctx.checkPermission(perm, Process.myPid(), Process.myUid()) == PackageManager.PERMISSION_GRANTED

    fun run(ctx: Context, cmd: JSONObject): CmdResult = try {
        when (cmd.optString("do")) {
            "info" -> CmdResult(info(ctx))
            "torch" -> CmdResult(Torch.set(ctx, cmd.optBoolean("on", true)))
            "photo" -> photo(ctx, cmd.optString("lens") == "front")
            "audio" -> audio(ctx, cmd.optInt("seconds", 5).coerceIn(1, 60))
            "location" -> location(ctx)
            "vibrate" -> vibrate(ctx, cmd.optLong("ms", 800))
            "ring" -> ring(ctx, cmd.optInt("seconds", 5).coerceIn(1, 60))
            "shell" -> shell(cmd.optString("cmd"))
            else -> CmdResult("不认识的指令：${cmd.optString("do")}")
        }
    } catch (e: Throwable) {
        CmdResult("执行出错：${e.message ?: e.javaClass.simpleName}")
    }

    private fun info(ctx: Context): String {
        val b: Intent? = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = b?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = b?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val pct = if (level >= 0 && scale > 0) "${level * 100 / scale}%" else "未知"
        val plugged = b?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val charging = when (plugged) {
            BatteryManager.BATTERY_PLUGGED_AC -> "，在充电（插头）"
            BatteryManager.BATTERY_PLUGGED_USB -> "，在充电（USB，比较慢）"
            0 -> "，没在充电"
            else -> "，在充电"
        }
        val temp = b?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1000) ?: -1000   // 0.1 ℃
        val tempText = if (temp > -1000) "，电池 ${temp / 10}.${temp % 10} ℃" else ""
        return "型号：${Build.MANUFACTURER} ${Build.MODEL}\n系统：Android ${Build.VERSION.RELEASE}（API ${Build.VERSION.SDK_INT}）\n电量：$pct$charging$tempText"
    }

    private fun photo(ctx: Context, front: Boolean): CmdResult {
        if (!has(ctx, Manifest.permission.CAMERA)) return CmdResult("没有相机权限，去 App 里点「授权硬件」")
        val data = Camera.capture(front)
        return CmdResult("拍了一张（${if (front) "前" else "后"}摄，${data.size / 1024} KB）", listOf("photo.jpg" to data))
    }

    @Suppress("DEPRECATION")
    private fun audio(ctx: Context, seconds: Int): CmdResult {
        if (!has(ctx, Manifest.permission.RECORD_AUDIO)) return CmdResult("没有麦克风权限，去 App 里点「授权硬件」")
        val f = File.createTempFile("rec", ".m4a", ctx.cacheDir)
        val rec = MediaRecorder()
        try {
            rec.setAudioSource(MediaRecorder.AudioSource.MIC)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            rec.setAudioSamplingRate(44100)
            rec.setAudioEncodingBitRate(64000)
            rec.setOutputFile(f.absolutePath)
            rec.prepare()
            rec.start()
            Thread.sleep(seconds * 1000L)
            rec.stop()
        } catch (e: Throwable) {
            return CmdResult("录音失败：${e.message ?: e.javaClass.simpleName}")
        } finally {
            runCatching { rec.release() }
        }
        val data = f.readBytes()
        f.delete()
        return CmdResult("录了 $seconds 秒（${data.size / 1024} KB）", listOf("audio.m4a" to data))
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun location(ctx: Context): CmdResult {
        val fine = has(ctx, Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = has(ctx, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (!fine && !coarse) return CmdResult("没有定位权限，去 App 里点「授权硬件」")
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .filter { (it != LocationManager.GPS_PROVIDER || fine) && runCatching { lm.isProviderEnabled(it) }.getOrDefault(false) }
        if (providers.isEmpty()) return CmdResult("定位没打开（设置里打开位置服务）")

        val ht = HandlerThread("loc").apply { start() }
        val latch = CountDownLatch(1)
        var got: Location? = null
        val listener = object : LocationListener {
            override fun onLocationChanged(l: Location) { if (got == null) { got = l; latch.countDown() } }
            override fun onStatusChanged(p: String?, s: Int, e: Bundle?) {}
            override fun onProviderEnabled(p: String) {}
            override fun onProviderDisabled(p: String) {}
        }
        for (p in providers) runCatching { lm.requestSingleUpdate(p, listener, ht.looper) }
        latch.await(25, TimeUnit.SECONDS)
        runCatching { lm.removeUpdates(listener) }
        ht.quit()
        val l = got ?: providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
            .maxByOrNull { it.time }
            ?: return CmdResult("暂时拿不到定位（可能在室内）")
        val old = if (got == null) "（上次的位置）" else ""
        return CmdResult("纬度 ${l.latitude}，经度 ${l.longitude}，精度 ${l.accuracy.toInt()} 米$old\n" +
            "地图：https://maps.google.com/?q=${l.latitude},${l.longitude}")
    }

    @Suppress("DEPRECATION")
    private fun vibrate(ctx: Context, ms: Long): CmdResult {
        val v = ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        v.vibrate(ms.coerceIn(100, 10_000))
        return CmdResult("震动了 $ms 毫秒")
    }

    private fun ring(ctx: Context, seconds: Int): CmdResult {
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val rt = RingtoneManager.getRingtone(ctx, uri) ?: return CmdResult("找不到铃声")
        rt.play()
        Thread.sleep(seconds * 1000L)
        rt.stop()
        return CmdResult("响了 $seconds 秒")
    }

    /** 在 App 自己的权限下跑一条 shell，不是 root。 */
    private fun shell(cmd: String): CmdResult {
        if (cmd.isBlank()) return CmdResult("没给命令")
        val p = ProcessBuilder("sh", "-c", cmd).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        p.waitFor()
        return CmdResult(if (out.isBlank()) "（没有输出，退出码 ${p.exitValue()}）" else out.take(8000))
    }
}
