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
 *  - 慢路：服务端没有即时信箱（404/405/501）时，轮询文件信箱；用即时信箱时也每 10 分钟看一眼文件信箱。
 */
class RemoteService : Service() {

    @Volatile private var running = false
    private var worker: Thread? = null
    private var wake: PowerManager.WakeLock? = null

    // 相机（实时画面 + 移动侦测）在 CameraHub 自己的线程里跑，指令循环照常收指令
    @Volatile private var hub: CameraHub? = null

    // 指令并发：收件循环只管把指令分出去，马上接着收下一条。
    //  - 快的（查信息、开关手电、查侦测状态…）走单独一条线，不用等慢的；
    //  - 慢的（拍照、录音、定位、测速、开直播…）几个一起跑；
    //  - 两条指令要用同一个相机 / 麦克风时，后来的马上回「正忙」，不默默排队。
    private val lanes = CommandLanes()

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
        hub?.let { h -> Thread({ h.shutdown() }, "hub-stop").start() }
        hub = null
        worker?.interrupt(); worker = null
        runCatching { wake?.release() }; wake = null
        Torch.releaseLegacy()
        Bus.push("已停止")
        stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() {
        running = false; Bus.running = false
        lanes.shutdown()
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
        hub = CameraHub(this, p, cloud, device, serviceRunning = { running }, status = ::notifyText).also { it.resume() }

        var useRelay = true
        var lastFileCheck = 0L
        var lastError = ""
        while (running) {
            if (useRelay) {
                try {
                    val msgs = cloud.relayWait(RemoteBox.inbox(device))
                    lastError = ""
                    for (cmd in msgs) dispatch(cloud, cmd, device, viaRelay = true, filesDir = filesDir)
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
                // 旧的发送端还会写文件信箱，隔一会儿看一眼（省电：以前 30 秒一次，现在 10 分钟）
                if (System.currentTimeMillis() - lastFileCheck < FILE_CHECK_MS) continue
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
                dispatch(cloud, cmd, device, viaRelay = false, filesDir = filesDir)
            }
            if (!useRelay) sleep(2000)
        }
    }

    /** 现在开着哪些费电的东西（info 指令的最后一行）。 */
    private fun powerText(h: CameraHub?): String {
        val on = ArrayList<String>()
        if (h?.monitor?.on == true) on.add("移动侦测（相机一直开着，最费电，要插着电）")
        if (h?.liveActive() == true) on.add("实时画面")
        else if (h?.cameraOn == true && h.monitor.on != true) on.add("相机")
        return if (on.isEmpty()) "耗电：只在待命收指令" else "耗电：开着 " + on.joinToString("、")
    }

    /** 把一条指令交给快线或慢线去做（不在收件循环里做，免得一条慢的挡住后面的）。 */
    private fun dispatch(cloud: Cloud, cmd: JSONObject, device: String, viaRelay: Boolean, filesDir: String) {
        if (cmd.optString("id").isBlank()) cmd.put("id", java.util.UUID.randomUUID().toString())
        val id = cmd.optString("id")
        val action = cmd.optString("do")
        // 相机开着时手电要等相机设好（几百毫秒），走慢线
        val fast = action in QUICK && !(action == "torch" && hub?.cameraOn == true)
        lanes.submit(id, fast) {
            try { execute(cloud, cmd, device, viaRelay, filesDir) }
            catch (e: Throwable) { Bus.push("指令 $action 出错：${e.message ?: e.javaClass.simpleName}") }
        }
    }

    /** 执行一条指令，回执原路返回。 */
    private fun execute(cloud: Cloud, cmd: JSONObject, device: String, viaRelay: Boolean, filesDir: String) {
        val p = Prefs(this)
        val id = cmd.optString("id").ifBlank { java.util.UUID.randomUUID().toString() }
        val outbox = "/小橘推送/遥控/$device/回执"

        fun replyTo(to: String, r: JSONObject) {
            try {
                if (viaRelay) cloud.relaySend(RemoteBox.receipt(device, to), r)
                else cloud.upload("$outbox/$to.json", r.toString().toByteArray(Charsets.UTF_8), "application/json; charset=utf-8")
            } catch (e: Exception) { Bus.push("传回执失败：${e.message}") }
        }
        fun reply(r: JSONObject) = replyTo(id, r)

        if (p.pair.isNotBlank() && cmd.optString("pair") != p.pair) {
            Bus.push("有一条指令口令不对，拒绝")
            reply(JSONObject().put("id", id).put("ok", false).put("text", "配对口令不对"))
            return
        }

        val action = cmd.optString("do")
        Bus.push("执行：$action")
        val h = hub

        if (action == "cancel") {
            // 取消一条还在做的慢指令（测速、录音…）：打断它，替它回一句「已取消」
            val target = cmd.optString("target")
            val ok = lanes.cancel(target)
            if (ok) replyTo(target, JSONObject().put("id", target).put("ok", false).put("text", "已取消"))
            Bus.push(if (ok) "取消了 $target" else "要取消的 $target 已经做完了")
            reply(JSONObject().put("id", id).put("do", action).put("ok", ok)
                .put("text", if (ok) "已取消" else "那条已经做完了，没东西可取消"))
            return
        }

        // 同一个相机 / 麦克风只能一条指令用：在用就马上回「正忙」
        val res = when (action) {
            "photo", "torch" -> if (h?.cameraOn == true) null else "camera"
            "video" -> if (cmd.optString("transport") == "ws") null else "camera"
            "audio" -> "mic"
            "bench" -> "bench"
            else -> null
        }
        if (res != null) {
            val other = lanes.take(res, label(action))
            if (other != null) {
                val what = when (res) { "camera" -> "相机"; "mic" -> "麦克风"; else -> "测速" }
                reply(JSONObject().put("id", id).put("do", action).put("ok", false).put("busy", true)
                    .put("text", "$what 正在忙（正在$other），等它做完再试"))
                return
            }
        }
        try {
            // 慢的指令先回一句「收到了」（看的一端带了 ack 才回，老版本只认第一条回执）
            if (cmd.optBoolean("ack") && action !in QUICK) {
                reply(JSONObject().put("id", id).put("do", action).put("ok", true).put("pending", true)
                    .put("text", "收到了，正在${label(action)}…"))
            }
            notifyText("正在被远程使用：${label(action)}")
            run(cloud, cmd, action, id, device, viaRelay, filesDir, ::reply)
        } finally {
            if (res != null) lanes.release(res)
        }
    }

    private fun run(cloud: Cloud, cmd: JSONObject, action: String, id: String, device: String, viaRelay: Boolean,
                    filesDir: String, reply: (JSONObject) -> Unit) {
        val h = hub
        if (action == "video") {
            if (cmd.optString("transport") == "ws") startLive(cmd, id, reply)
            else if (h?.cameraOn == true) {
                reply(JSONObject().put("id", id).put("ok", false).put("text", "相机正在用（移动侦测 / 实时画面），旧方式看不了，更新小橘推送"))
                restoreText()
            } else streamVideo(cloud, cmd, device, viaRelay, id, reply)
            return
        }
        if (action == "video_set" || (action == "torch" && h?.cameraOn == true)) {
            adjustLive(cmd, action, id, reply)
            return
        }
        if (action == "bench") {
            // 模型测速：大约一分钟，跑完回一段报告
            val text = ModelBench(this, h).run { Bus.push(it) }
            Bus.push(text.lineSequence().firstOrNull().orEmpty())
            reply(JSONObject().put("id", id).put("do", action).put("ok", true).put("text", text))
            restoreText()
            return
        }
        if (action in setOf("monitor", "monitor_status", "events", "event_get", "event_delete")) {
            monitorCommand(cloud, cmd, action, id, viaRelay, reply)
            return
        }
        if (action == "audio" && h?.micOn == true) {
            reply(JSONObject().put("id", id).put("ok", false).put("text", "移动侦测正在录声音，麦克风被占用了（可以在侦测设置里关掉声音）"))
            restoreText()
            return
        }

        val result = if (action == "photo" && h?.cameraOn == true) {
            // 相机开着（侦测 / 直播）：从画面截一张，不打断
            val d = h.grab()
            if (d == null) CmdResult("相机正在用，没截到画面，再试一次")
            else CmdResult("从画面截了一张（相机正在侦测 / 直播，${d.size / 1024} KB）", listOf("photo.jpg" to d))
        } else Commands.run(this, cmd).let { r ->
            // 设备信息里写上现在开着哪些费电的东西，方便看电耗在哪
            if (action == "info") CmdResult(r.text + "\n" + powerText(h), r.files) else r
        }

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
        restoreText()
    }

    /**
     * 实时画面（新）：WebSocket 长连接推流到服务端的直播通道，不限时长，看的人都走了就停。
     * 相机和编码器在 CameraHub 里（和移动侦测共用）。回执马上回：连上了回「开始直播」，连不上回原因。
     */
    private fun startLive(cmd: JSONObject, id: String, reply: (JSONObject) -> Unit) {
        fun fail(text: String) {
            reply(JSONObject().put("id", id).put("do", "video").put("ok", false).put("text", text))
            restoreText()
        }
        val h = hub ?: run { fail("还没准备好，过几秒再试"); return }
        val room = cmd.optString("room")
        if (room.isBlank() || room.toByteArray(Charsets.UTF_8).size > 200) { fail("直播指令缺少房间名"); return }
        if (checkPermission(android.Manifest.permission.CAMERA, Process.myPid(), Process.myUid()) != PackageManager.PERMISSION_GRANTED) {
            fail("没有相机权限"); return
        }
        val p = Prefs(this)
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
        h.startLive(client, cmd, av, withAudio)
        // lan：同一个 Wi-Fi 时 iPhone 直接连这些地址（更快），连不上就接着用云盘
        reply(JSONObject().put("id", id).put("do", "video").put("ok", true).put("text", okText)
            .put("lan", JSONArray(h.lanAddresses())))
        Bus.push("$okText，WebSocket，${h.settings.fps} 帧/秒，${if (h.settings.codec == LiveSettings.H264) "H.264" else "JPEG"}")
    }

    /** 直播 / 侦测中调相机：video_set（镜头、清晰度、画质、帧率、亮度、变焦、手电、编码），或相机开着时的手电指令。 */
    private fun adjustLive(cmd: JSONObject, action: String, id: String, reply: (JSONObject) -> Unit) {
        val h = hub
        if (h == null || !h.cameraOn) {
            reply(JSONObject().put("id", id).put("do", action).put("ok", false).put("text", "现在没在直播"))
            restoreText()
            return
        }
        val s = h.settings
        val c = if (action == "torch") JSONObject().put("torch", cmd.optBoolean("on", true)) else cmd
        s.codecNote = ""
        val changed = h.adjust(c)
        // 等相机设好：换镜头 / 清晰度 / 编码要重开相机（大约 1 秒），手电、亮度、变焦一下就好
        val reopen = c.has("lens") || c.has("width") || c.has("codec")
        try { Thread.sleep(if (reopen) 1200 else 300) } catch (e: InterruptedException) { }
        val notes = listOf(s.unsupported, s.codecNote).filter { it.isNotEmpty() }
        val text = (if (changed.isEmpty()) "没有要改的" else "已调整：" + changed.joinToString("、")) +
            (if (notes.isEmpty()) "" else "（${notes.joinToString("；")}）")
        reply(JSONObject().put("id", id).put("do", action).put("ok", true).put("text", text))
        Bus.push(text)
        restoreText()
    }

    /**
     * 移动侦测的指令：
     *   monitor        改设置 / 开关（字段见 MonitorConfig），回现在的状态
     *   monitor_status 状态（开没开、今天几段、待备份、Telegram 怎么样）
     *   events         录好的事件列表（新的在前，带小图），limit / before 翻页
     *   event_get      取一段视频（name）：备份过的给云盘路径；小的直接放回执里；大的先传到云盘
     *   event_delete   删掉手机上的一段（云盘上的备份不动）
     */
    private fun monitorCommand(cloud: Cloud, cmd: JSONObject, action: String, id: String, viaRelay: Boolean, reply: (JSONObject) -> Unit) {
        val h = hub
        fun done(ok: Boolean, text: String, extra: (JSONObject) -> Unit = {}) {
            val r = JSONObject().put("id", id).put("do", action).put("ok", ok).put("text", text)
            extra(r)
            reply(r)
            restoreText()
        }
        if (h == null) { done(false, "还没准备好，过几秒再试"); return }
        if (action == "monitor" && cmd.optBoolean("on", h.monitor.on) &&
            checkPermission(android.Manifest.permission.CAMERA, Process.myPid(), Process.myUid()) != PackageManager.PERMISSION_GRANTED) {
            done(false, "没有相机权限，去 App 里点「授权硬件」"); return
        }
        try {
            when (action) {
                "monitor" -> { val t = h.setMonitor(cmd); Bus.push(t); done(true, t) { it.put("status", h.statusJson()) } }
                "monitor_status" -> done(true, h.describe()) { it.put("status", h.statusJson()) }
                "events" -> {
                    val list = h.eventsJson(cmd.optInt("limit", 30), cmd.optString("before"))
                    done(true, "${list.length()} 段") { it.put("events", list) }
                }
                "event_delete" -> {
                    val name = cmd.optString("name")
                    done(h.store.delete(name), if (h.store.get(name) == null) "删了 $name" else "没删掉 $name")
                }
                "event_get" -> {
                    val name = cmd.optString("name")
                    val e = h.store.get(name) ?: run { done(false, "手机上没有 $name（可能已经满了被删掉，看云盘备份）"); return }
                    val f = h.store.mov(name)
                    val files = JSONArray()
                    when {
                        !e.video || !f.exists() -> {
                            val j = h.store.jpg(name)
                            if (j.exists()) files.put(JSONObject().put("name", "$name.jpg").put("data", Base64.encodeToString(j.readBytes(), Base64.NO_WRAP)))
                        }
                        e.uploaded.isNotEmpty() -> files.put(e.uploaded)
                        viaRelay && f.length() <= RemoteBox.INLINE_LIMIT ->
                            files.put(JSONObject().put("name", "$name.mov").put("data", Base64.encodeToString(f.readBytes(), Base64.NO_WRAP)))
                        else -> files.put(h.uploader.uploadNow(e))
                    }
                    done(true, "$name，${e.durMs / 1000} 秒") { it.put("files", files).put("event", e.toJson()) }
                }
            }
        } catch (ex: Exception) {
            done(false, "出错了：${ex.message ?: ex.javaClass.simpleName}")
        }
    }

    /** 指令做完，通知栏恢复成现在的状态。 */
    private fun restoreText() {
        val h = hub
        notifyText(when {
            h == null -> "待命中，等指令"
            h.monitor.on && h.liveActive() -> "正在被远程使用：移动侦测 + 实时画面"
            h.monitor.on -> "正在被远程使用：移动侦测中"
            h.liveActive() -> "正在被远程使用：实时画面"
            else -> "待命中，等指令"
        })
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
        "torch" to "手电筒", "vibrate" to "震动", "ring" to "响铃", "info" to "设备信息", "shell" to "命令", "video" to "实时画面", "video_set" to "调实时画面",
        "monitor" to "移动侦测设置", "monitor_status" to "移动侦测状态", "events" to "看录像列表", "event_get" to "取录像", "event_delete" to "删录像", "bench" to "模型测速", "cancel" to "取消")[a] ?: a

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
        /** 一下就做完的指令：走快线，不等慢的 */
        /** 即时信箱好用时，多久看一眼文件信箱（只有很老的发送端还写文件信箱） */
        const val FILE_CHECK_MS = 10 * 60_000L
        val QUICK = setOf("info", "torch", "vibrate", "monitor", "monitor_status", "events", "event_delete", "cancel")
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
