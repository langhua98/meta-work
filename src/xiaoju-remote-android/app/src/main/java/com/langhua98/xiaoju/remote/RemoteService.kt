package com.langhua98.xiaoju.remote

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 待命服务（前台服务 + 常驻通知，被远程使用时通知栏写明在做什么）。
 * 流程和 xiaoju-remote 仓库的 RemoteEngine 一致：
 *  - 快路：即时信箱长轮询，指令一到马上执行，回执也走即时信箱（文件 5 MB 以内 base64 放回执里）。
 *  - 慢路：服务端没有即时信箱（404/405/501）时，轮询文件信箱；用即时信箱时也每 30 秒看一眼文件信箱。
 */
class RemoteService : Service() {

    @Volatile private var running = false
    private var worker: Thread? = null
    private var wake: PowerManager.WakeLock? = null

    // 直播在单独的线程里跑，指令循环照常收指令。新的直播指令会先停掉旧的直播。
    @Volatile private var live: Thread? = null
    @Volatile private var liveSettings: LiveSettings? = null
    private val liveStop = java.util.concurrent.atomic.AtomicBoolean(false)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { stopAll(); return START_NOT_STICKY }
        startAsForeground("待命中，等指令")
        if (!running) {
            running = true
            Bus.running = true
            Bus.push("开始待命")
            wake = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "xiaoju:remote").apply { acquire() }
            worker = Thread({ loop() }, "remote-loop").apply { start() }
        }
        return START_STICKY
    }

    private fun stopAll() {
        running = false
        Bus.running = false
        liveStop.set(true)
        worker?.interrupt(); worker = null
        runCatching { wake?.release() }; wake = null
        Torch.releaseLegacy()
        Bus.push("已停止")
        stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() {
        running = false; Bus.running = false
        runCatching { wake?.release() }
        super.onDestroy()
    }

    private fun loop() {
        val p = Prefs(this)
        if (p.token.isBlank()) { Bus.push("先填云盘令牌"); post { stopAll() }; return }
        Net.init(this)
        val cloud = Cloud(p.base, p.token)
        val device = p.device
        val inbox = "/小橘推送/遥控/$device/收件"
        val filesDir = "/小橘推送/遥控/$device/文件"

        try { Bus.push("云盘：${cloud.me()}") } catch (e: Exception) { Bus.push("连不上云盘：${e.message}") }

        var useRelay = true
        var lastFileCheck = 0L
        var lastError = ""
        while (running) {
            if (useRelay) {
                try {
                    val msgs = cloud.relayWait(RemoteBox.inbox(device))
                    lastError = ""
                    for (cmd in msgs) execute(cloud, cmd, device, viaRelay = true, filesDir = filesDir)
                } catch (e: Exception) {
                    if (!running) break
                    if (Cloud.relayMissing(e)) {
                        useRelay = false
                        Bus.push("云盘服务端还没有即时信箱，改用文件信箱（会慢几秒）")
                    } else {
                        val msg = e.message ?: e.javaClass.simpleName
                        if (msg != lastError) Bus.push("收件箱读不了：$msg")
                        lastError = msg
                        sleep(2000)
                    }
                }
                // 旧的发送端还会写文件信箱，每 30 秒看一眼
                if (System.currentTimeMillis() - lastFileCheck < 30_000) continue
            }
            lastFileCheck = System.currentTimeMillis()
            val items = cloud.list(inbox).filter { !it.isFolder && it.name.endsWith(".json") }.sortedBy { it.name }
            for (it in items) {
                if (!running) break
                if (p.isSeen(it.id)) continue
                p.markSeen(it.id)
                val cmd = try { JSONObject(String(cloud.download(it.id), Charsets.UTF_8)) } catch (e: Exception) {
                    Bus.push("收到一条看不懂的指令，跳过"); continue
                }
                if (!cmd.has("id")) cmd.put("id", it.name.removeSuffix(".json"))
                execute(cloud, cmd, device, viaRelay = false, filesDir = filesDir)
            }
            if (!useRelay) sleep(2000)
        }
    }

    /** 执行一条指令，回执原路返回。 */
    private fun execute(cloud: Cloud, cmd: JSONObject, device: String, viaRelay: Boolean, filesDir: String) {
        val p = Prefs(this)
        val id = cmd.optString("id").ifBlank { java.util.UUID.randomUUID().toString() }
        val outbox = "/小橘推送/遥控/$device/回执"

        fun reply(r: JSONObject) {
            try {
                if (viaRelay) cloud.relaySend(RemoteBox.receipt(device, id), r)
                else cloud.upload("$outbox/$id.json", r.toString().toByteArray(Charsets.UTF_8), "application/json; charset=utf-8")
            } catch (e: Exception) { Bus.push("传回执失败：${e.message}") }
        }

        if (p.pair.isNotBlank() && cmd.optString("pair") != p.pair) {
            Bus.push("有一条指令口令不对，拒绝")
            reply(JSONObject().put("id", id).put("ok", false).put("text", "配对口令不对"))
            return
        }

        val action = cmd.optString("do")
        Bus.push("执行：$action")
        notifyText("正在被远程使用：${label(action)}")

        if (action == "video") {
            if (cmd.optString("transport") == "ws") startLive(cmd, device, id, ::reply)
            else streamVideo(cloud, cmd, device, viaRelay, id, ::reply)
            return
        }
        if (action == "video_set" || (action == "torch" && live?.isAlive == true)) {
            adjustLive(cmd, action, id, ::reply)
            return
        }
        if (live?.isAlive == true && action == "photo") {
            reply(JSONObject().put("id", id).put("ok", false).put("text", "正在直播，相机被占用了，先停止看画面"))
            notifyText("正在被远程使用：实时画面")
            return
        }

        val result = Commands.run(this, cmd)

        val files = JSONArray()
        for ((name, bytes) in result.files) {
            if (viaRelay && bytes.size <= RemoteBox.INLINE_LIMIT) {
                files.put(JSONObject().put("name", name).put("data", Base64.encodeToString(bytes, Base64.NO_WRAP)))
                continue
            }
            val path = "$filesDir/$id-$name"
            try {
                cloud.upload(path, bytes, if (name.endsWith(".jpg")) "image/jpeg" else "application/octet-stream")
                files.put(path)
            } catch (e: Exception) { Bus.push("传文件失败：$name") }
        }

        val at = SimpleDateFormat("MM-dd HH:mm:ss", Locale.getDefault()).format(Date())
        reply(JSONObject().put("id", id).put("do", action).put("ok", true)
            .put("text", result.text).put("files", files).put("at", at))
        Bus.push("完成：$action — ${result.text.lineSequence().firstOrNull().orEmpty()}")
        notifyText("待命中，等指令")
    }

    /**
     * 实时画面（新）：WebSocket 长连接推流到服务端的直播通道，不限时长，看的人都走了就停。
     * 相机回调里只管把帧交给 OkHttp 的发送队列，队列积压就丢帧，相机不会被网络卡住。
     * 回执马上回：连上了回「开始直播」，连不上回原因（看的一端据此提示）。
     */
    private fun startLive(cmd: JSONObject, device: String, id: String, reply: (JSONObject) -> Unit) {
        fun fail(text: String) {
            reply(JSONObject().put("id", id).put("do", "video").put("ok", false).put("text", text))
            notifyText("待命中，等指令")
        }
        val room = cmd.optString("room")
        if (room.isBlank() || room.toByteArray(Charsets.UTF_8).size > 200) { fail("直播指令缺少房间名"); return }
        if (checkPermission(android.Manifest.permission.CAMERA, Process.myPid(), Process.myUid()) != PackageManager.PERMISSION_GRANTED) {
            fail("没有相机权限"); return
        }
        // 先停掉正在进行的直播（比如看的一端刚关又开）
        live?.let { old -> liveStop.set(true); runCatching { old.join(5000) } }
        liveStop.set(false)

        val p = Prefs(this)
        val settings = LiveSettings(cmd.optString("lens") == "front", cmd.optInt("width", 480),
            cmd.optInt("quality", 50), cmd.optInt("fps", 10))
        settings.apply(cmd)   // 开播时就带的亮度、变焦、手电
        val fps = settings.fps
        // av=true：新查看器，画面带时间戳；audio=true：还要声音（要麦克风权限）
        val av = cmd.optBoolean("av", false)
        val wantAudio = av && cmd.optBoolean("audio", false)
        val micOk = checkPermission(android.Manifest.permission.RECORD_AUDIO, Process.myPid(), Process.myUid()) == PackageManager.PERMISSION_GRANTED
        val withAudio = wantAudio && micOk
        val client = StreamClient(Net.okHttp(), StreamClient.pubUrl(p.base, room), p.token)
        if (!client.connect()) {
            fail(if (client.error == "HTTP 404") "云盘服务端还没有直播通道（要先更新服务端）" else "连不上直播通道：${client.error}")
            return
        }
        val okText = when {
            withAudio -> "开始直播（画面 + 声音）"
            wantAudio -> "开始直播（没有麦克风权限，只有画面）"
            else -> "开始直播"
        }
        reply(JSONObject().put("id", id).put("do", "video").put("ok", true).put("text", okText))
        Bus.push("$okText，WebSocket，$fps 帧/秒")
        notifyText(if (withAudio) "正在被远程使用：实时画面（含声音）" else "正在被远程使用：实时画面")

        liveSettings = settings
        live = Thread({
            val mic = if (withAudio) AudioCapture { data, codec, ts ->
                if (client.subs > 0) client.sendAudio(StreamClient.audio(data, codec, ts))
            } else null
            if (mic != null && !mic.start()) Bus.push("声音没开成：${mic.error}")
            try {
                val end = System.currentTimeMillis() + LIVE_MAX_MS
                Camera.live(settings, running = {
                    running && !liveStop.get() && !client.closed && !client.nobodyWatching(20_000, 8_000) &&
                        System.currentTimeMillis() < end
                }) { jpg, rot, ts ->
                    if (client.subs > 0) client.send(if (av) StreamClient.frameTs(jpg, rot, ts) else StreamClient.frame(jpg, rot))
                }
            } catch (e: Exception) {
                Bus.push("直播出错：${e.message}")
            } finally {
                mic?.stop()
                client.close()
                Bus.push("直播结束：发出 ${client.sent} 帧，网络跟不上丢了 ${client.dropped} 帧")
                notifyText("待命中，等指令")
            }
        }, "live").apply { start() }
    }

    /** 直播中调参数：video_set（镜头、清晰度、画质、帧率、亮度、变焦、手电），或直播时的手电指令。 */
    private fun adjustLive(cmd: JSONObject, action: String, id: String, reply: (JSONObject) -> Unit) {
        val s = liveSettings
        if (live?.isAlive != true || s == null) {
            reply(JSONObject().put("id", id).put("do", action).put("ok", false).put("text", "现在没在直播"))
            notifyText("待命中，等指令")
            return
        }
        val c = if (action == "torch") JSONObject().put("torch", cmd.optBoolean("on", true)) else cmd
        val changed = s.apply(c)
        try { Thread.sleep(1200) } catch (e: InterruptedException) { }   // 等相机设好（换镜头大约 1 秒）
        val text = (if (changed.isEmpty()) "没有要改的" else "已调整：" + changed.joinToString("、")) +
            (if (s.unsupported.isEmpty()) "" else "（${s.unsupported}）")
        reply(JSONObject().put("id", id).put("do", action).put("ok", true).put("text", text))
        Bus.push(text)
        notifyText("正在被远程使用：实时画面")
    }

    /** 实时画面：连续抓帧推到视频信箱。只走即时信箱（文件信箱太慢，撑不起视频）。 */
    private fun streamVideo(cloud: Cloud, cmd: JSONObject, device: String, viaRelay: Boolean, id: String, reply: (JSONObject) -> Unit) {
        if (!viaRelay) { reply(JSONObject().put("id", id).put("ok", false).put("text", "实时画面要即时信箱，当前走的是文件信箱")); notifyText("待命中，等指令"); return }
        if (checkPermission(android.Manifest.permission.CAMERA, Process.myPid(), Process.myUid()) != PackageManager.PERMISSION_GRANTED) {
            reply(JSONObject().put("id", id).put("ok", false).put("text", "没有相机权限")); notifyText("待命中，等指令"); return
        }
        val front = cmd.optString("lens") == "front"
        val seconds = cmd.optInt("seconds", 20).coerceIn(3, 60)
        val fps = cmd.optInt("fps", 3).coerceIn(1, 8)
        val width = cmd.optInt("width", 480).coerceIn(240, 960)
        val quality = cmd.optInt("quality", 40).coerceIn(20, 80)
        val box = RemoteBox.video(device)
        var seq = 0
        Bus.push("开始直播（$seconds 秒）")
        try {
            Camera.stream(front, width, quality, fps, seconds * 1000L, running = { running }) { jpg, rot, _ ->
                if (jpg.size > RemoteBox.INLINE_LIMIT) return@stream
                try {
                    cloud.relaySend(box, JSONObject().put("seq", seq++).put("rot", rot)
                        .put("jpg", Base64.encodeToString(jpg, Base64.NO_WRAP)))
                } catch (e: Exception) { /* 丢帧 */ }
            }
        } catch (e: Exception) {
            reply(JSONObject().put("id", id).put("ok", false).put("text", "直播出错：${e.message}")); notifyText("待命中，等指令"); return
        }
        reply(JSONObject().put("id", id).put("do", "video").put("ok", true).put("text", "直播结束，共 $seq 帧"))
        Bus.push("直播结束，共 $seq 帧")
        notifyText("待命中，等指令")
    }

    private fun label(a: String) = mapOf("photo" to "拍照", "audio" to "录音", "location" to "定位",
        "torch" to "手电筒", "vibrate" to "震动", "ring" to "响铃", "info" to "设备信息", "shell" to "命令", "video" to "实时画面", "video_set" to "调实时画面")[a] ?: a

    private fun sleep(ms: Long) { try { Thread.sleep(ms) } catch (e: InterruptedException) { } }
    private fun post(r: () -> Unit) { Handler(Looper.getMainLooper()).post(r) }

    // ---- 通知 ----

    @Suppress("DEPRECATION")
    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), piFlags())
        val stop = PendingIntent.getService(this, 1,
            Intent(this, RemoteService::class.java).setAction(ACTION_STOP), piFlags())
        val b = if (Build.VERSION.SDK_INT >= 26) Api26.builder(this) else Notification.Builder(this)
        b.setContentTitle("小橘遥控")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, "停止", stop)
        return b.build()
    }

    private fun piFlags() = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 23) FLAG_IMMUTABLE else 0)

    private fun startAsForeground(text: String) {
        val n = buildNotification(text)
        if (Build.VERSION.SDK_INT >= 29) Api29.startForeground(this, NOTIF_ID, n) else startForeground(NOTIF_ID, n)
    }

    private fun notifyText(text: String) {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIF_ID, buildNotification(text))
    }

    companion object {
        const val NOTIF_ID = 42
        /** 一次直播最长多久（服务端也会在 4 小时断开） */
        const val LIVE_MAX_MS = 4L * 60 * 60 * 1000
        const val ACTION_STOP = "stop"
        const val CHANNEL = "xiaoju-remote"
        private const val FLAG_IMMUTABLE = 0x04000000

        fun start(ctx: Context) {
            val i = Intent(ctx, RemoteService::class.java)
            if (Build.VERSION.SDK_INT >= 26) Api26.startForegroundService(ctx, i) else ctx.startService(i)
        }

        fun stop(ctx: Context) {
            ctx.startService(Intent(ctx, RemoteService::class.java).setAction(ACTION_STOP))
        }
    }
}

/** Android 8.0+ 才有的接口，单独放一个类，老系统不会加载它。 */
@TargetApi(26)
private object Api26 {
    fun builder(ctx: Context): Notification.Builder {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(RemoteService.CHANNEL, "小橘遥控", NotificationManager.IMPORTANCE_LOW))
        return Notification.Builder(ctx, RemoteService.CHANNEL)
    }
    fun startForegroundService(ctx: Context, i: Intent) { ctx.startForegroundService(i) }
}

/** Android 10+：前台服务要声明类型，只声明已经授权的，避免 Android 14 上抛异常。 */
@TargetApi(29)
private object Api29 {
    fun startForeground(s: Service, id: Int, n: Notification) {
        fun ok(p: String) = s.checkPermission(p, Process.myPid(), Process.myUid()) == PackageManager.PERMISSION_GRANTED
        var t = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        // 相机、麦克风这两种类型 Android 11（API 30）才有
        if (Build.VERSION.SDK_INT >= 30) {
            if (ok(android.Manifest.permission.CAMERA)) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            if (ok(android.Manifest.permission.RECORD_AUDIO)) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        if (ok(android.Manifest.permission.ACCESS_FINE_LOCATION) || ok(android.Manifest.permission.ACCESS_COARSE_LOCATION))
            t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        s.startForeground(id, n, t)
    }
}

/** App 和服务之间传运行状态和日志。 */
object Bus {
    @Volatile var running = false
    private val lines = ArrayList<String>()
    @Volatile var onLog: ((List<String>) -> Unit)? = null

    @Synchronized fun push(line: String) {
        val t = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())
        lines.add("$t  $line")
        while (lines.size > 200) lines.removeAt(0)
        val snap = ArrayList(lines)
        Handler(Looper.getMainLooper()).post { onLog?.invoke(snap) }
    }

    @Synchronized fun snapshot(): List<String> = ArrayList(lines)
}
