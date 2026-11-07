package com.langhua98.xiaoju.remote

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.Process
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * 相机总管：实时画面和移动侦测共用一个相机、一个硬件 H.264 编码器。
 *
 *   相机（NV21）─┬─ 移动侦测（每 200 ms 看一帧）→ 有动静：截图、Telegram 提醒、开始录
 *               ├─ H.264 编码器 ─┬─ 实时画面（有人在看、要 H.264 时）：云盘直播通道 / 同一个 Wi-Fi 直连
 *               │                └─ 事件录像（内存里一直留着最近几秒，有动静才写文件）
 *               └─ JPEG（实时画面的兼容模式、硬件编码用不了时）
 *
 * 实时画面卡顿的处理：网络跟不上丢了帧，马上要一个关键帧（4.2 不支持「要关键帧」，就重开编码器，
 * 重开后第一帧就是关键帧，卡大约 0.1 秒，不用等满 1 秒）；老是丢就把码率降下来，好了再慢慢升回去。
 *
 * 侦测开着时相机一直开着；只看实时画面时，看的人走了相机就关。
 * 直播中看的一端可以换镜头、调参数，直播完恢复侦测自己的设置。
 */
class CameraHub(
    private val ctx: Context, private val prefs: Prefs, cloud: Cloud, private val device: String,
    private val serviceRunning: () -> Boolean, private val status: (String) -> Unit,
) {
    val settings = LiveSettings(false, 640, 50, 10, LiveSettings.H264)
    @Volatile var monitor: MonitorConfig = prefs.monitor
        private set

    val store = EventStore(eventsDir())
    private val detector = MotionDetector()
    private val recorder = EventRecorder(store)
    private val notifier = Notifier(cloud, prefs, device)
    val uploader = Uploader(cloud, store, device, enabled = { monitor.upload }, busy = { watching() })
    private val work = Executors.newSingleThreadExecutor()   // 截图、存小图、发提醒（不卡相机）

    @Volatile private var thread: Thread? = null

    // 实时画面：一次直播 = 云盘直播通道的推流 + 同一个 Wi-Fi 里直连进来的观看端
    private class Live(val room: String, val av: Boolean, val audio: Boolean, val until: Long) {
        val started = System.currentTimeMillis()
        @Volatile var cloud: StreamClient? = null
        val lan = java.util.concurrent.CopyOnWriteArrayList<LanViewer>()
        @Volatile var lastWatched = 0L
        fun sinks(): List<LiveSink> = listOfNotNull<LiveSink>(cloud) + lan
        fun watched(): List<LiveSink> = sinks().filter { !it.isClosed && it.watchers > 0 }
    }
    @Volatile private var live: Live? = null
    private val lanServer = LanServer(roomOk = { r -> live?.room == r }, onViewer = { v -> lanViewer(v) })

    // 码率自适应：网络跟不上（丢帧）就降，稳了再升
    @Volatile private var rateScale = 1.0
    @Volatile private var restartEnc = false
    @Volatile private var keyAt = 0L
    private val drops = java.util.concurrent.ConcurrentLinkedQueue<Long>()
    @Volatile private var lastDrop = 0L
    @Volatile private var rateChangedAt = 0L

    // 编码（相机线程上用；编出来的帧在编码器线程上分发）
    @Volatile private var enc: H264Encoder? = null
    private var encConf = ""
    private var encSince = 0L
    private var fed = 0
    @Volatile private var h264Broken = false
    @Volatile private var rot = 0
    @Volatile private var encW = 0
    @Volatile private var encH = 0
    private val jpg = ByteArrayOutputStream(64 * 1024)

    // 侦测
    private var lastLook = 0L
    private var detVersion = -1
    private var detTweak = -1
    private var detRot = -1
    @Volatile private var regionsDirty = true
    @Volatile private var lastEvent = ""

    // 声音
    private var mic: AudioCapture? = null
    private var micFailedAt = 0L

    // 侦测 / 直播时拍照：从画面截一张
    @Volatile private var grabLatch: CountDownLatch? = null
    @Volatile private var grabbed: ByteArray? = null
    @Volatile private var grabW = 0
    @Volatile private var grabH = 0
    @Volatile private var grabRot = 0

    private var housekeepAt = 0L

    init {
        applyMonitor()
        recorder.onClosed = { e ->
            Bus.push(if (e.video) "录好一段：${e.name}，${e.durMs / 1000} 秒" else "记下一次动静：${e.name}（只有截图）")
            work.execute { store.cleanup() }
        }
        recorder.onError = { Bus.push(it) }
    }

    val cameraOn get() = thread?.isAlive == true
    /** 侦测正在用麦克风（录音指令要让一让） */
    val micOn get() = mic != null
    fun liveActive() = live != null
    fun watching() = live?.watched()?.isNotEmpty() == true
    private fun wanted() = serviceRunning() && (monitor.on || liveActive())

    /** 服务启动时：上次开着侦测就接着侦测。 */
    fun resume() {
        if (!monitor.on) return
        settings.apply(monitor.cameraJson())
        Bus.push("接着移动侦测")
        ensure()
        status(stateText())
    }

    /** monitor 指令：改侦测设置（只改指令里出现的字段），返回现在的状态（给回执）。 */
    fun setMonitor(cmd: JSONObject): String {
        val old = monitor
        val m = old.merge(cmd)
        monitor = m
        prefs.monitor = m
        applyMonitor()
        // 直播中先不动相机（看的人在调），直播完再换成侦测的设置
        if (m.on && !liveActive()) settings.apply(m.cameraJson())
        if (m.on) {
            ensure()
            if (!old.on && m.notify) notifier.text("移动侦测已打开，有动静会发到这里。")
        }
        status(stateText())
        return describe()
    }

    /**
     * 开始给一个观看端推实时画面（连好了的云盘直播通道）。原来的直播会被替换。
     * 同时在局域网里开着直连：同一个 Wi-Fi 的 iPhone 可以拿着同一个房间名直接连过来（地址见 lanAddresses）。
     */
    fun startLive(c: StreamClient, cmd: JSONObject, av: Boolean, audio: Boolean) {
        live?.let { old -> old.sinks().forEach { it.close() } }
        val s = JSONObject(cmd.toString())
        if (!s.has("codec")) s.put("codec", LiveSettings.JPEG)   // 老查看器只认 JPEG
        settings.codecNote = ""
        settings.apply(s)
        val l = Live(cmd.optString("room"), av, audio, System.currentTimeMillis() + RemoteService.LIVE_MAX_MS)
        l.cloud = c
        live = l
        rateScale = 1.0
        if (!lanServer.start()) Bus.push("局域网直连开不了（端口被占用），只能经云盘看")
        forceKey()
        ensure()
        status(stateText())
    }

    /** 局域网直连的地址（ip:端口），放进开始直播的回执里给 iPhone。 */
    fun lanAddresses(): List<String> = lanServer.addresses()

    private fun lanViewer(v: LanViewer) {
        val l = live
        if (l == null) { v.close(); return }
        l.lan.add(v)
        Bus.push("同一个 Wi-Fi 的 ${v.remote} 直连来看了")
        forceKey()
    }

    /** 直播中 / 侦测中调相机（video_set、手电）。 */
    fun adjust(cmd: JSONObject): List<String> = settings.apply(cmd)

    /** 从画面截一张照片（相机开着时拍照用），转正、JPEG。拿不到返回 null。 */
    fun grab(timeoutMs: Long = 3_000): ByteArray? {
        if (!cameraOn) return null
        grabbed = null
        val l = CountDownLatch(1)
        grabLatch = l
        if (!l.await(timeoutMs, TimeUnit.MILLISECONDS)) { grabLatch = null; return null }
        grabLatch = null
        val d = grabbed ?: return null
        return Snapshot.jpeg(d, grabW, grabH, grabRot, 92, 0)
    }

    /** 状态（monitor_status 指令）。 */
    fun statusJson(): JSONObject {
        val today = SimpleDateFormat("yyyyMMdd", Locale.US).format(Date())
        val list = store.list()
        return JSONObject().put("monitor", monitor.toJson()).put("camera", cameraOn).put("live", liveActive())
            .put("recording", recorder.recording).put("score", detector.score.toDouble()).put("noise", detector.noise.toDouble())
            .put("today", list.count { it.name.startsWith(today) }).put("events", list.size)
            .put("last", list.firstOrNull()?.name ?: "").put("pending", store.pendingUpload().size)
            .put("storage_mb", store.usedBytes() / (1 shl 20)).put("free_mb", store.dir.usableSpace / (1 shl 20))
            .put("telegram", notifier.status).put("backup", uploader.status).put("codec_note", settings.codecNote)
            .put("objects", if (objectsOn()) "FastestDet" else "")
    }

    /** 事件列表（events 指令）：新的在前，带小图（base64）。 */
    fun eventsJson(limit: Int, before: String): JSONArray {
        val a = JSONArray()
        for (e in store.list().filter { before.isEmpty() || it.name < before }.take(limit.coerceIn(1, 100))) {
            val o = e.toJson()
            val t = store.thumb(e.name)
            if (t.exists() && t.length() < 64 * 1024) o.put("thumb", Base64.encodeToString(t.readBytes(), Base64.NO_WRAP))
            o.put("size", store.mov(e.name).length())
            a.put(o)
        }
        return a
    }

    fun shutdown() {
        live?.sinks()?.forEach { it.close() }
        lanServer.close()
        thread?.let { runCatching { it.join(5_000) } }
        uploader.close()
        work.shutdown()
        detect.shutdown()
    }

    // ---- 相机线程 ----

    @Synchronized private fun ensure() {
        if (thread?.isAlive == true || !wanted()) return
        thread = Thread({ cameraLoop() }, "camera-hub").apply { start() }
    }

    private fun cameraLoop() {
        try {
            while (wanted()) {
                try {
                    Camera.live(settings, running = {
                        if (Thread.currentThread() === thread) housekeep()
                        wanted()
                    }) { nv21, w, h, r, ts -> frame(nv21, w, h, r, ts) }
                } catch (e: Exception) {
                    Bus.push("相机打不开：${e.message}，5 秒后再试")
                    live?.let { endLive() }
                    var waited = 0
                    while (wanted() && waited < 5_000) { try { Thread.sleep(200) } catch (ie: InterruptedException) { return }; waited += 200 }
                }
            }
        } finally {
            closeEncoder()
            setMic(false)
            recorder.close()
            detector.reset()
            if (live != null) endLive()
            status(stateText())
        }
    }

    /** 相机线程上定时（大约 0.3 秒一次）：直播该不该结束、麦克风开关、录像按时结束。 */
    private fun housekeep() {
        val now = System.currentTimeMillis()
        if (now - housekeepAt < 300) return
        housekeepAt = now
        live?.let { l ->
            l.lan.removeAll { it.isClosed }
            if (l.watched().isNotEmpty()) l.lastWatched = now
            val cloudGone = l.cloud?.isClosed != false
            when {
                now > l.until -> endLive()
                cloudGone && l.lan.isEmpty() -> endLive()
                l.lastWatched == 0L && now - l.started > 20_000 -> endLive()   // 一直没人来看
                l.lastWatched > 0 && now - l.lastWatched > 8_000 -> endLive()  // 看的人都走了
            }
        }
        // 15 秒没丢过帧：码率慢慢升回去
        if (rateScale < 1.0 && now - lastDrop > 15_000 && now - rateChangedAt > 15_000) {
            rateScale = minOf(1.0, rateScale * 1.25); rateChangedAt = now
            Bus.push("网络好了，码率升到 ${(rateScale * 100).toInt()}%")
        }
        setMic((watching() && live?.audio == true) || (monitor.on && monitor.audio))
        if (!monitor.on && recorder.recording) recorder.close()
        recorder.tick()
    }

    private fun endLive() {
        val l = live ?: return
        live = null
        val sinks = l.sinks()
        sinks.forEach { it.close() }
        Bus.push("直播结束：发出 ${sinks.sumOf { it.sentFrames }} 帧，网络跟不上丢了 ${sinks.sumOf { it.droppedFrames }} 帧")
        // 恢复侦测自己的相机设置（看的人可能换了镜头、开了手电）
        if (monitor.on) settings.apply(monitor.cameraJson().put("torch", false).put("exposure", 0).put("zoom", 0))
        status(stateText())
    }

    private fun frame(nv21: ByteArray, w: Int, h: Int, r: Int, ts: Long) {
        rot = r
        grabLatch?.let { l ->
            if (grabbed == null) { grabbed = nv21.copyOf(); grabW = w; grabH = h; grabRot = r; l.countDown() }
        }
        val l = live
        val sinks = l?.watched().orEmpty()
        val m = monitor
        val wantH264 = !h264Broken && (m.on || (sinks.isNotEmpty() && settings.codec == LiveSettings.H264))
        if (wantH264) h264(nv21, w, h, ts)
        else if (enc != null) closeEncoder()
        if (l != null && sinks.isNotEmpty() && (settings.codec == LiveSettings.JPEG || h264Broken)) jpegLive(l, sinks, nv21, w, h, r, ts)
        if (m.on) look(nv21, w, h, r, ts)
    }

    private fun h264(nv21: ByteArray, w: Int, h: Int, ts: Long) {
        if (!H264.sizeOk(w, h)) { giveUp("这台手机的相机没有硬件编码合适的尺寸（${w}×$h）"); return }
        val rate = maxOf(150_000, (H264.bitrate(settings.width, settings.fps, settings.quality) * rateScale).toInt())
        val conf = "${w}x$h/${settings.fps}/$rate"
        try {
            if (restartEnc) { restartEnc = false; closeEncoder() }   // 重开：第一帧就是关键帧
            if (enc == null || conf != encConf) {
                closeEncoder()
                encW = w; encH = h
                val e = H264Encoder(w, h, settings.fps, rate) { data, key, t -> onEncoded(data, key, t) }
                enc = e; encConf = conf; encSince = System.currentTimeMillis(); fed = 0; encRate = rate
                Bus.push("H.264 硬件编码：${e.name}，${w}×$h，${rate / 1000} kbps")
            }
            val e = enc ?: return
            if (e.feed(nv21, ts)) fed++
            if (e.produced == 0 && fed > 5 && System.currentTimeMillis() - encSince > 3000) giveUp("硬件编码器不出画面")
        } catch (t: Throwable) {
            giveUp("硬件编码出错：${t.message ?: t.javaClass.simpleName}")
        }
    }

    /** 编码器线程上：编好的一帧发给每个在看的（云盘 / 直连），交给录像。 */
    private fun onEncoded(data: ByteArray, key: Boolean, ts: Long) {
        val l = live
        if (l != null && settings.codec == LiveSettings.H264) {
            val sinks = l.watched()
            if (sinks.isNotEmpty()) {
                val msg = StreamClient.h264(data, rot, ts, key)
                // 积压超过大约 0.3 秒的数据就丢（延迟不越拖越长），丢了马上要关键帧
                val limit = maxOf(24L * 1024, encRate / 8L * 3 / 10)
                var dropped = false
                for (s in sinks) if (!s.sendH264(msg, key, limit) && s.watchers > 0) dropped = true
                if (!dropped) framesOut.incrementAndGet()
                if (dropped) onDrop()
            }
        }
        if (monitor.on) recorder.video(data, key, ts, encW, encH, rot)
    }

    @Volatile private var encRate = 500_000

    /** 实时画面发出去的帧数（测速时看跑模型会不会拖慢直播） */
    private val framesOut = java.util.concurrent.atomic.AtomicInteger()

    /** 量 windowMs 毫秒里实时画面每秒发出几帧（阻塞）。 */
    fun framesPerSecond(windowMs: Long): Double {
        val a = framesOut.get()
        Thread.sleep(windowMs)
        return (framesOut.get() - a) * 1000.0 / windowMs
    }

    /** 丢了帧：要一个关键帧；5 秒里丢了 3 次以上就把码率降到 70%（最低 30%）。 */
    private fun onDrop() {
        val now = System.currentTimeMillis()
        lastDrop = now
        drops.add(now)
        while ((drops.peek() ?: now) < now - 5_000) drops.poll()
        if (drops.size >= 3 && now - rateChangedAt > 3_000 && rateScale > 0.3) {
            rateScale = maxOf(0.3, rateScale * 0.7); rateChangedAt = now; drops.clear()
            Bus.push("网络跟不上，码率降到 ${(rateScale * 100).toInt()}%")
        }
        forceKey()
    }

    /** 马上出一个关键帧：4.4+ 直接要，更老的重开编码器（一秒最多一次）。 */
    private fun forceKey() {
        val now = System.currentTimeMillis()
        if (now - keyAt < 1_000) return
        keyAt = now
        if (android.os.Build.VERSION.SDK_INT >= 19) enc?.requestKeyframe() else if (enc != null) restartEnc = true
    }

    private fun giveUp(why: String) {
        closeEncoder()
        h264Broken = true
        settings.codecNote = "$why，实时画面改用 JPEG" + if (monitor.on) "，侦测只能存截图" else ""
        Bus.push(settings.codecNote)
    }

    private fun closeEncoder() { enc?.close(); enc = null; encConf = "" }

    private fun jpegLive(l: Live, sinks: List<LiveSink>, nv21: ByteArray, w: Int, h: Int, r: Int, ts: Long) {
        try {
            jpg.reset()
            YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), settings.quality, jpg)
            val b = jpg.toByteArray()
            val msg = if (l.av) StreamClient.frameTs(b, r, ts) else StreamClient.frame(b, r)
            for (s in sinks) s.send(msg)
            framesOut.incrementAndGet()
        } catch (e: Throwable) { /* 丢这一帧 */ }
    }

    /** 移动侦测：每 200 ms 看一帧；新的事件截一张图、发提醒。 */
    private fun look(nv21: ByteArray, w: Int, h: Int, r: Int, ts: Long) {
        val now = System.currentTimeMillis()
        if (now - lastLook < 200) return
        lastLook = now
        if (settings.version != detVersion || settings.tweak != detTweak) {
            detVersion = settings.version; detTweak = settings.tweak
            detector.reset()   // 换了镜头、调了亮度：重新学背景
        }
        if (regionsDirty || r != detRot) { detector.setRegions(monitor.regions, r); detRot = r; regionsDirty = false }
        val moving = detector.analyze(nv21, w, h)
        if (moving && recorder.motion(ts)) {
            val e = recorder.current ?: return
            lastEvent = e.name
            Bus.push("有动静：${e.name}")
            newEvent(e, nv21.copyOf(), w, h, r)
            return
        }
        // 事件进行中：每 1.5 秒再认一次（新进来的人、刚才没认出来的）
        if (recorder.recording && !detBusy && now - lastDetect > 1_500 && objectsOn()) {
            lastDetect = now
            detBusy = true
            val copy = nv21.copyOf()
            detect.execute { try { later(copy, w, h, r) } finally { detBusy = false } }
        }
    }

    // ---- 认出动的是什么（FastestDet，见 ObjectDetector）：在单独一个后台线程上，一个核，只在有动静时跑 ----
    private val detect = Executors.newSingleThreadExecutor()
    @Volatile private var detBusy = false
    @Volatile private var lastDetect = 0L
    private val evCounts = HashMap<Int, Int>()      // 这次事件里认出过的：类别 → 最多同时几个
    @Volatile private var evNotified = false

    private fun objectsOn() = ObjectDetector.usable

    /** 认一帧，只留「会动的、而且就在画面变了的地方」的（不然床、椅子、停着的车每次都算进来）。 */
    private fun recognize(nv21: ByteArray, w: Int, h: Int): List<ObjectDetector.Detection> {
        if (!ObjectDetector.ready(ctx)) return emptyList()
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        return ObjectDetector.detect(nv21, w, h).filter { it.canMove && detector.moved(it.x1, it.y1, it.x2, it.y2) }
    }

    /** 记下这次认出来的，更新正在录的那段的标签。返回现在的汇总。 */
    private fun merge(ds: List<ObjectDetector.Detection>): String = synchronized(evCounts) {
        for ((cls, n) in ds.groupingBy { it.cls }.eachCount()) evCounts[cls] = maxOf(evCounts[cls] ?: 0, n)
        val text = ObjectDetector.summaryOf(evCounts)
        recorder.current?.labels = text
        text
    }

    /** 新的事件：认一下是什么、截图（框出来）、存小图、发提醒。 */
    private fun newEvent(e: EventInfo, nv21: ByteArray, w: Int, h: Int, r: Int) {
        synchronized(evCounts) { evCounts.clear() }
        evNotified = false
        lastDetect = System.currentTimeMillis()
        detBusy = true
        val m = monitor
        detect.execute {
            try {
                val ds = if (objectsOn()) recognize(nv21, w, h) else emptyList()
                val labels = merge(ds)
                e.labels = labels
                if (labels.isNotEmpty()) Bus.push("认出来：$labels")
                val big = Snapshot.jpeg(nv21, w, h, r, 80, 0, ds)
                store.jpg(e.name).writeBytes(big)
                store.thumb(e.name).writeBytes(Snapshot.jpeg(nv21, w, h, r, 60, 200, ds))
                // 「只在有人时提醒」：认出人才发；认不了（没带模型）就照常发
                if (m.notify && (!m.personOnly || !ObjectDetector.ready(ctx) || ds.any { it.isPerson })) {
                    notifier.event(e.at, big, m.cooldownMin, labels)
                    evNotified = true
                }
            } catch (ex: Exception) {
                Bus.push("存截图出错：${ex.message}")
            } finally { detBusy = false }
        }
    }

    /** 事件进行中又认了一次：补上标签；「只在有人时提醒」又还没发过时，认出人就发。 */
    private fun later(nv21: ByteArray, w: Int, h: Int, r: Int) {
        val ds = recognize(nv21, w, h)
        if (ds.isEmpty()) return
        val labels = merge(ds)
        val m = monitor
        if (m.notify && m.personOnly && !evNotified && ds.any { it.isPerson }) {
            evNotified = true
            val e = recorder.current ?: return
            notifier.event(e.at, Snapshot.jpeg(nv21, w, h, r, 80, 0, ds), m.cooldownMin, labels)
        }
    }

    private fun setMic(on: Boolean) {
        val m = mic
        if (on && m == null) {
            if (System.currentTimeMillis() - micFailedAt < 60_000) return
            if (ctx.checkPermission(android.Manifest.permission.RECORD_AUDIO, Process.myPid(), Process.myUid()) != PackageManager.PERMISSION_GRANTED) {
                micFailedAt = System.currentTimeMillis(); return
            }
            val a = AudioCapture { data, codec, ts -> onAudio(data, codec, ts) }
            if (a.start()) mic = a else { micFailedAt = System.currentTimeMillis(); Bus.push("声音没开成：${a.error}") }
        } else if (!on && m != null) {
            m.stop(); mic = null
        }
    }

    private fun onAudio(data: ByteArray, codec: Int, ts: Long) {
        val l = live
        if (l != null && l.audio) {
            val sinks = l.watched()
            if (sinks.isNotEmpty()) { val msg = StreamClient.audio(data, codec, ts); for (s in sinks) s.sendAudio(msg) }
        }
        if (monitor.on && monitor.audio) recorder.audio(data, if (codec == StreamClient.AUDIO_ULAW_8K) 8000 else 16000, ts)
    }

    private fun applyMonitor() {
        val m = monitor
        recorder.preMs = m.preSec * 1000L
        recorder.postMs = m.postSec * 1000L
        detector.sensitivity = m.sensitivity
        regionsDirty = true
    }

    private fun stateText(): String = when {
        monitor.on && liveActive() -> "正在被远程使用：移动侦测 + 实时画面"
        monitor.on -> "正在被远程使用：移动侦测中"
        liveActive() -> "正在被远程使用：实时画面"
        else -> "待命中，等指令"
    }

    /** 回执里的一句话。 */
    fun describe(): String {
        val m = monitor
        if (!m.on) return "移动侦测已关闭（录好的 ${store.list().size} 段还在手机上）"
        val area = if (m.regions.isEmpty()) "整个画面" else "${m.regions.size} 个区域"
        return "移动侦测已打开：$area，灵敏度 ${m.sensitivity}，动静前 ${m.preSec} 秒、后 ${m.postSec} 秒" +
            (if (m.notify) "，Telegram 提醒（隔 ${m.cooldownMin} 分钟）" else "，不提醒") +
            (if (m.upload) "，慢慢备份到云盘" else "，只存手机") +
            (if (h264Broken) "（${settings.codecNote}）" else "")
    }

    private fun eventsDir(): File {
        val ext = try { ctx.getExternalFilesDir("events") } catch (e: Exception) { null }
        if (ext != null && (ext.isDirectory || ext.mkdirs()) && ext.canWrite()) return ext
        return File(ctx.filesDir, "events")
    }
}

/** NV21 → 转正的 JPEG（maxW > 0 时缩小到这么宽，做小图）。 */
object Snapshot {
    /** boxes：认出来的东西，在图上框出来、写上名字 */
    fun jpeg(nv21: ByteArray, w: Int, h: Int, rot: Int, quality: Int, maxW: Int,
             boxes: List<ObjectDetector.Detection> = emptyList()): ByteArray {
        val raw = ByteArrayOutputStream()
        YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), 95, raw)
        val r = (rot % 360 + 360) % 360
        if (r == 0 && maxW <= 0 && quality >= 95 && boxes.isEmpty()) return raw.toByteArray()
        val src = BitmapFactory.decodeByteArray(raw.toByteArray(), 0, raw.size()) ?: return raw.toByteArray()
        val outW = if (r == 90 || r == 270) h else w
        val scale = if (maxW in 1 until outW) maxW.toFloat() / outW else 1f
        val m = Matrix().apply { postRotate(r.toFloat()); postScale(scale, scale) }
        var bmp = Bitmap.createBitmap(src, 0, 0, w, h, m, true)
        if (boxes.isNotEmpty()) {
            if (!bmp.isMutable) { val c = bmp.copy(Bitmap.Config.ARGB_8888, true); if (bmp !== src) bmp.recycle(); bmp = c }
            draw(bmp, boxes, r)
        }
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, quality, out)
        if (bmp !== src) bmp.recycle()
        src.recycle()
        return out.toByteArray()
    }

    private fun draw(bmp: Bitmap, boxes: List<ObjectDetector.Detection>, rot: Int) {
        val c = android.graphics.Canvas(bmp)
        val bw = bmp.width.toFloat(); val bh = bmp.height.toFloat()
        val line = android.graphics.Paint().apply {
            style = android.graphics.Paint.Style.STROKE; color = 0xFFFF8C1A.toInt(); strokeWidth = maxOf(2f, bw / 160)
        }
        val text = android.graphics.Paint().apply {
            color = 0xFFFFFFFF.toInt(); textSize = maxOf(10f, bw / 22); isAntiAlias = true
        }
        val back = android.graphics.Paint().apply { color = 0xCCFF8C1A.toInt() }
        for (d in boxes) {
            val u = ObjectDetector.upright(d, rot)
            val x1 = u[0] * bw; val y1 = u[1] * bh; val x2 = u[2] * bw; val y2 = u[3] * bh
            c.drawRect(x1, y1, x2, y2, line)
            val label = d.name
            val tw = text.measureText(label) + text.textSize / 2
            val ty = if (y1 > text.textSize * 1.3f) y1 else y2 + text.textSize * 1.3f
            c.drawRect(x1, ty - text.textSize * 1.25f, x1 + tw, ty, back)
            c.drawText(label, x1 + text.textSize / 4, ty - text.textSize * 0.3f, text)
        }
    }
}
