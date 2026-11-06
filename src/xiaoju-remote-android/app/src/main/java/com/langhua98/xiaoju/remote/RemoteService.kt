package com.langhua98.xiaoju.remote

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 待命服务：轮询云盘收件箱，执行指令，把结果传回回执箱。 */
class RemoteService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var loop: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { stopEverything(); return START_NOT_STICKY }
        startAsForeground("待命中，等指令")
        Bus.running = true
        Bus.push("服务启动，待命中")
        if (loop == null) loop = scope.launch { run() }
        return START_STICKY
    }

    private fun stopEverything() {
        Bus.running = false
        loop?.cancel(); loop = null
        scope.cancel()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() { Bus.running = false; super.onDestroy() }

    private suspend fun run() {
        val p = Prefs(this)
        if (p.token.isBlank()) { Bus.push("没填云盘令牌，先在 App 里填好再开"); stopEverything(); return }
        val cloud = Cloud(p.base, p.token)
        val device = p.device
        val inbox = "/小橘推送/遥控/$device/收件"
        val outbox = "/小橘推送/遥控/$device/回执"
        val filesDir = "/小橘推送/遥控/$device/文件"
        val seen = getSharedPreferences("seen", Context.MODE_PRIVATE)

        runCatching { Bus.push("云盘：${cloud.me()}") }
            .onFailure { Bus.push("连不上云盘：${it.message}") }

        while (scope.isActive) {
            try {
                val items = cloud.listOrEmpty(inbox).filter { !it.isFolder && it.name.endsWith(".json") }
                    .sortedBy { it.name }
                for (it in items) {
                    if (seen.getBoolean(it.id, false)) continue
                    handle(cloud, it, outbox, filesDir)
                    seen.edit().putBoolean(it.id, true).apply()
                }
            } catch (e: Throwable) {
                Bus.push("轮询出错：${e.message}")
            }
            delay(4000)
        }
    }

    private suspend fun handle(cloud: Cloud, item: CloudItem, outbox: String, filesDir: String) {
        val p = Prefs(this)
        val cmd = runCatching { JSONObject(String(cloud.download(item.id))) }.getOrNull()
            ?: run { Bus.push("收到一条看不懂的指令，跳过"); return }
        val id = cmd.optString("id").ifBlank { item.name.removeSuffix(".json") }

        // 配对口令不对就拒绝执行
        if (p.pair.isNotBlank() && cmd.optString("pair") != p.pair) {
            Bus.push("有一条指令口令不对，拒绝")
            cloud.uploadText("$outbox/$id.json",
                JSONObject().put("id", id).put("ok", false).put("text", "配对口令不对").toString())
            return
        }

        val action = cmd.optString("do")
        Bus.push("执行：$action")
        notify("正在被远程使用：$action")

        val result = runCatching { Commands.run(this, cmd) }
            .getOrElse { CmdResult("执行出错：${it.message}") }

        val filePaths = JSONArray()
        for ((name, bytes) in result.files) {
            val path = "$filesDir/$id-$name"
            runCatching {
                cloud.upload(path, bytes, if (name.endsWith(".jpg")) "image/jpeg" else "application/octet-stream")
                filePaths.put(path)
            }.onFailure { Bus.push("传文件失败：${it.message}") }
        }

        val receipt = JSONObject()
            .put("id", id).put("do", action).put("ok", true)
            .put("text", result.text).put("files", filePaths)
            .put("at", SimpleDateFormat("MM-dd HH:mm:ss", Locale.getDefault()).format(Date()))
        runCatching { cloud.uploadText("$outbox/$id.json", receipt.toString()) }
            .onFailure { Bus.push("传回执失败：${it.message}") }

        Bus.push("完成：$action — ${result.text.lineSequence().firstOrNull() ?: ""}")
        notify("待命中，等指令")
    }

    /** 按当前已授权的权限组前台服务类型：没授权的不声明，避免安卓 14 上抛异常。dataSync 始终有。 */
    private fun fgsType(): Int {
        if (Build.VERSION.SDK_INT < 29) return 0
        var t = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        fun ok(p: String) = checkSelfPermission(p) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (ok(android.Manifest.permission.CAMERA)) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        if (ok(android.Manifest.permission.RECORD_AUDIO)) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if (ok(android.Manifest.permission.ACCESS_FINE_LOCATION) || ok(android.Manifest.permission.ACCESS_COARSE_LOCATION))
            t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        return t
    }

    private fun startAsForeground(text: String) {
        val n = buildNotification(text)
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIF_ID, n, fgsType())
        else startForeground(NOTIF_ID, n)
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(
            this, 1, Intent(this, RemoteService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(this, App.CHANNEL)
            .setContentTitle("小橘遥控")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_launcher_fg)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, "停止", stop)
            .build()
    }

    private fun notify(text: String) {
        val nm = getSystemService(android.app.NotificationManager::class.java)
        nm.notify(NOTIF_ID, buildNotification(text))
    }

    companion object {
        const val NOTIF_ID = 42
        const val ACTION_STOP = "stop"

        fun start(ctx: Context) {
            val i = Intent(ctx, RemoteService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }
        fun stop(ctx: Context) {
            ctx.startService(Intent(ctx, RemoteService::class.java).setAction(ACTION_STOP))
        }
    }
}

/** App 和服务之间传运行状态和日志。 */
object Bus {
    @Volatile var running = false
    private val lines = ArrayDeque<String>()
    @Volatile var onLog: ((List<String>) -> Unit)? = null

    @Synchronized fun push(line: String) {
        val t = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())
        lines.addLast("$t  $line")
        while (lines.size > 200) lines.removeFirst()
        val snapshot = lines.toList()
        android.os.Handler(android.os.Looper.getMainLooper()).post { onLog?.invoke(snapshot) }
    }

    @Synchronized fun snapshot(): List<String> = lines.toList()
}
