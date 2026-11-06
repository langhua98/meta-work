package com.langhua98.xiaoju.remote

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.location.Location
import android.location.LocationManager
import android.media.MediaRecorder
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.core.content.ContextCompat
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.File
import kotlin.coroutines.resume

data class CmdResult(val text: String, val files: List<Pair<String, ByteArray>> = emptyList())

/** 一条指令 → 执行 → 结果。会用硬件的前先查权限，没授权就直接说清楚，不崩。 */
object Commands {

    private fun has(ctx: Context, perm: String) =
        ContextCompat.checkSelfPermission(ctx, perm) == PackageManager.PERMISSION_GRANTED

    suspend fun run(ctx: Context, cmd: JSONObject): CmdResult {
        return when (cmd.optString("do")) {
            "info" -> CmdResult(info(ctx))
            "torch" -> torch(ctx, cmd.optBoolean("on", true))
            "photo" -> photo(ctx, cmd.optString("lens") == "front")
            "audio" -> audio(ctx, cmd.optInt("seconds", 5).coerceIn(1, 60))
            "location" -> location(ctx)
            "vibrate" -> vibrate(ctx, cmd.optLong("ms", 800))
            "ring" -> ring(ctx, cmd.optInt("seconds", 5).coerceIn(1, 60))
            "shell" -> shell(cmd.optString("cmd"))
            else -> CmdResult("不认识的指令：${cmd.optString("do")}")
        }
    }

    private fun info(ctx: Context): String {
        val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
        val level = bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return buildString {
            append("型号：${Build.MANUFACTURER} ${Build.MODEL}\n")
            append("系统：Android ${Build.VERSION.RELEASE}（API ${Build.VERSION.SDK_INT}）\n")
            append("电量：$level%")
        }
    }

    private fun torch(ctx: Context, on: Boolean): CmdResult {
        val mgr = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = mgr.cameraIdList.firstOrNull {
            mgr.getCameraCharacteristics(it)
                .get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return CmdResult("这台手机没有闪光灯")
        mgr.setTorchMode(id, on)
        return CmdResult("手电筒已${if (on) "打开" else "关闭"}")
    }

    private suspend fun photo(ctx: Context, front: Boolean): CmdResult {
        if (!has(ctx, Manifest.permission.CAMERA)) return CmdResult("没有相机权限，去 App 里点「授权硬件」")
        val data = withTimeoutOrNull(15_000) { Camera.capture(ctx, front) }
            ?: return CmdResult("拍照超时")
        return CmdResult("拍了一张（${if (front) "前" else "后"}摄，${data.size / 1024} KB）", listOf("photo.jpg" to data))
    }

    @SuppressLint("MissingPermission")
    private suspend fun audio(ctx: Context, seconds: Int): CmdResult {
        if (!has(ctx, Manifest.permission.RECORD_AUDIO)) return CmdResult("没有麦克风权限，去 App 里点「授权硬件」")
        val f = File.createTempFile("rec", ".m4a", ctx.cacheDir)
        val rec = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(ctx) else @Suppress("DEPRECATION") MediaRecorder()
        try {
            rec.setAudioSource(MediaRecorder.AudioSource.MIC)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            rec.setOutputFile(f.absolutePath)
            rec.prepare(); rec.start()
            delay(seconds * 1000L)
            rec.stop()
        } catch (e: Throwable) {
            return CmdResult("录音失败：${e.message}")
        } finally { runCatching { rec.release() } }
        val data = f.readBytes(); f.delete()
        return CmdResult("录了 $seconds 秒（${data.size / 1024} KB）", listOf("audio.m4a" to data))
    }

    @SuppressLint("MissingPermission")
    private suspend fun location(ctx: Context): CmdResult {
        val fine = has(ctx, Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = has(ctx, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (!fine && !coarse) return CmdResult("没有定位权限，去 App 里点「授权硬件」")
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val provider = if (fine) LocationManager.GPS_PROVIDER else LocationManager.NETWORK_PROVIDER
        val loc: Location? = withTimeoutOrNull(20_000) {
            suspendCancellableCoroutine { cont ->
                val listener = object : android.location.LocationListener {
                    override fun onLocationChanged(l: Location) {
                        lm.removeUpdates(this)
                        if (cont.isActive) cont.resume(l)
                    }
                    @Deprecated("") override fun onStatusChanged(p: String?, s: Int, e: android.os.Bundle?) {}
                    override fun onProviderDisabled(p: String) {}
                    override fun onProviderEnabled(p: String) {}
                }
                try {
                    lm.requestLocationUpdates(provider, 0L, 0f, listener, ctx.mainLooper)
                } catch (e: Throwable) { if (cont.isActive) cont.resume(null) }
                cont.invokeOnCancellation { lm.removeUpdates(listener) }
            }
        } ?: lm.getLastKnownLocation(provider)
        return if (loc == null) CmdResult("暂时拿不到定位（可能在室内或定位没开）")
        else CmdResult("纬度 ${loc.latitude}，经度 ${loc.longitude}，精度 ${loc.accuracy} 米\n地图：https://maps.google.com/?q=${loc.latitude},${loc.longitude}")
    }

    private fun vibrate(ctx: Context, ms: Long): CmdResult {
        val v = if (Build.VERSION.SDK_INT >= 31)
            (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as android.os.VibratorManager).defaultVibrator
        else @Suppress("DEPRECATION") ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        v.vibrate(VibrationEffect.createOneShot(ms.coerceIn(100, 10_000), VibrationEffect.DEFAULT_AMPLITUDE))
        return CmdResult("震动了 ${ms} 毫秒")
    }

    private suspend fun ring(ctx: Context, seconds: Int): CmdResult {
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val rt = RingtoneManager.getRingtone(ctx, uri)
        rt.play()
        delay(seconds * 1000L)
        rt.stop()
        return CmdResult("响了 $seconds 秒")
    }

    /** 开发用：在 App 沙盒里跑一条 shell。只有 App 自己的权限，不是 root。 */
    private fun shell(cmd: String): CmdResult {
        if (cmd.isBlank()) return CmdResult("没给命令")
        return try {
            val p = ProcessBuilder("sh", "-c", cmd).redirectErrorStream(true).start()
            val out = p.inputStream.bufferedReader().readText()
            p.waitFor()
            CmdResult(if (out.isBlank()) "（没有输出，退出码 ${p.exitValue()}）" else out.take(8000))
        } catch (e: Throwable) { CmdResult("跑不了：${e.message}") }
    }
}
