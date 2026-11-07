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
 *               ├─ H.264 编码器 ─┬─ 实时画面（有人在看、要 H.264 时）
 *               │                └─ 事件录像（内存里一直留着最近几秒，有动静才写文件）
 *               └─ JPEG（实时画面的兼容模式、硬件编码用不了时）
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

    // 实时画面
    @Volatile private var client: StreamClient? = null
    @Volatile private var liveAv = false
    @Volatile private var liveAudio = false
    @Volatile private var liveUntil = 0L

    // 编码（相机线程上用；编出来的帧在编码器线程上分发）
    @Volatile private var enc: H264Encoder? = null
    private var encConf = ""
    private var encSince = 0L
    private var fed = 0
    @Volatile private var h264Broken = false
    @Volatile private var rot = 0
    @Volatile private var encW = 0
    @Volatile private var encH = 0
    @Volatile private var askKeyAt = 0L
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
    fun liveActive() = client?.closed == false
    fun watching() = client?.let { !it.closed && it.subs > 0 } == true
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

    /** 开始给一个观看端推实时画面（连好了的 StreamClient）。原来的直播会被替换。 */
    fun startLive(c: StreamClient, cmd: JSONObject, av: Boolean, audio: Boolean) {
        client?.close()
        val s = JSONObject(cmd.toString())
        if (!s.has("codec")) s.put("codec", LiveSettings.JPEG)   // 老查看器只认 JPEG
        settings.codecNote = ""
        settings.apply(s)
        liveAv = av; liveAudio = audio
        liveUntil = System.currentTimeMillis() + RemoteService.LIVE_MAX_MS
        client = c
        enc?.requestKeyframe()
        ensure()
        status(stateText())
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
        client?.close()
        thread?.let { runCatching { it.join(5_000) } }
        uploader.close()
        work.shutdown()
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
                    client?.let { endLive() }
                    var waited = 0
                    while (wanted() && waited < 5_000) { try { Thread.sleep(200) } catch (ie: InterruptedException) { return }; waited += 200 }
                }
            }
        } finally {
            closeEncoder()
            setMic(false)
            recorder.close()
            detector.reset()
            if (client != null) endLive()
            status(stateText())
        }
    }

    /** 相机线程上定时（大约 0.3 秒一次）：直播该不该结束、麦克风开关、录像按时结束。 */
    private fun housekeep() {
        val now = System.currentTimeMillis()
        if (now - housekeepAt < 300) return
        housekeepAt = now
        client?.let { c -> if (c.closed || c.nobodyWatching(20_000, 8_000) || now > liveUntil) endLive() }
        setMic((liveActive() && liveAudio && watching()) || (monitor.on && monitor.audio))
        if (!monitor.on && recorder.recording) recorder.close()
        recorder.tick()
    }

    private fun endLive() {
        val c = client ?: return
        client = null
        c.close()
        Bus.push("直播结束：发出 ${c.sent} 帧，网络跟不上丢了 ${c.dropped} 帧")
        // 恢复侦测自己的相机设置（看的人可能换了镜头、开了手电）
        if (monitor.on) settings.apply(monitor.cameraJson().put("torch", false).put("exposure", 0).put("zoom", 0))
        status(stateText())
    }

    private fun frame(nv21: ByteArray, w: Int, h: Int, r: Int, ts: Long) {
        rot = r
        grabLatch?.let { l ->
            if (grabbed == null) { grabbed = nv21.copyOf(); grabW = w; grabH = h; grabRot = r; l.countDown() }
        }
        val c = client
        val watch = c != null && !c.closed && c.subs > 0
        val m = monitor
        val wantH264 = !h264Broken && (m.on || (watch && settings.codec == LiveSettings.H264))
        if (wantH264) h264(nv21, w, h, ts)
        else if (enc != null) closeEncoder()
        if (watch && (settings.codec == LiveSettings.JPEG || h264Broken)) jpegLive(c!!, nv21, w, h, r, ts)
        if (m.on) look(nv21, w, h, r, ts)
    }

    private fun h264(nv21: ByteArray, w: Int, h: Int, ts: Long) {
        if (!H264.sizeOk(w, h)) { giveUp("这台手机的相机没有硬件编码合适的尺寸（${w}×$h）"); return }
        val rate = H264.bitrate(settings.width, settings.fps, settings.quality)
        val conf = "${w}x$h/${settings.fps}/$rate"
        try {
            if (enc == null || conf != encConf) {
                closeEncoder()
                encW = w; encH = h
                val e = H264Encoder(w, h, settings.fps, rate) { data, key, t -> onEncoded(data, key, t) }
                enc = e; encConf = conf; encSince = System.currentTimeMillis(); fed = 0
                Bus.push("H.264 硬件编码：${e.name}，${w}×$h，${rate / 1000} kbps")
            }
            val e = enc ?: return
            if (e.feed(nv21, ts)) fed++
            if (e.produced == 0 && fed > 5 && System.currentTimeMillis() - encSince > 3000) giveUp("硬件编码器不出画面")
        } catch (t: Throwable) {
            giveUp("硬件编码出错：${t.message ?: t.javaClass.simpleName}")
        }
    }

    /** 编码器线程上：编好的一帧发给直播、交给录像。 */
    private fun onEncoded(data: ByteArray, key: Boolean, ts: Long) {
        val c = client
        if (c != null && !c.closed && settings.codec == LiveSettings.H264) {
            val limit = maxOf(48L * 1024, H264.bitrate(settings.width, settings.fps, settings.quality) / 8L / 2)
            if (!c.sendH264(StreamClient.h264(data, rot, ts, key), key, limit) && c.subs > 0) {
                val now = System.currentTimeMillis()
                if (now - askKeyAt > 500) { askKeyAt = now; enc?.requestKeyframe() }
            }
        }
        if (monitor.on) recorder.video(data, key, ts, encW, encH, rot)
    }

    private fun giveUp(why: String) {
        closeEncoder()
        h264Broken = true
        settings.codecNote = "$why，实时画面改用 JPEG" + if (monitor.on) "，侦测只能存截图" else ""
        Bus.push(settings.codecNote)
    }

    private fun closeEncoder() { enc?.close(); enc = null; encConf = "" }

    private fun jpegLive(c: StreamClient, nv21: ByteArray, w: Int, h: Int, r: Int, ts: Long) {
        try {
            jpg.reset()
            YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), settings.quality, jpg)
            val b = jpg.toByteArray()
            c.send(if (liveAv) StreamClient.frameTs(b, r, ts) else StreamClient.frame(b, r))
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
        if (!detector.analyze(nv21, w, h) || !recorder.motion(ts)) return
        val e = recorder.current ?: return
        lastEvent = e.name
        Bus.push("有动静：${e.name}")
        val copy = nv21.copyOf()
        val m = monitor
        work.execute {
            try {
                val big = Snapshot.jpeg(copy, w, h, r, 80, 0)
                store.jpg(e.name).writeBytes(big)
                store.thumb(e.name).writeBytes(Snapshot.jpeg(copy, w, h, r, 60, 200))
                if (m.notify) notifier.event(e.at, big, m.cooldownMin)
            } catch (ex: Exception) { Bus.push("存截图出错：${ex.message}") }
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
        val c = client
        if (c != null && liveAudio && c.subs > 0) c.sendAudio(StreamClient.audio(data, codec, ts))
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
    fun jpeg(nv21: ByteArray, w: Int, h: Int, rot: Int, quality: Int, maxW: Int): ByteArray {
        val raw = ByteArrayOutputStream()
        YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), 95, raw)
        val r = (rot % 360 + 360) % 360
        if (r == 0 && maxW <= 0 && quality >= 95) return raw.toByteArray()
        val src = BitmapFactory.decodeByteArray(raw.toByteArray(), 0, raw.size()) ?: return raw.toByteArray()
        val outW = if (r == 90 || r == 270) h else w
        val scale = if (maxW in 1 until outW) maxW.toFloat() / outW else 1f
        val m = Matrix().apply { postRotate(r.toFloat()); postScale(scale, scale) }
        val bmp = Bitmap.createBitmap(src, 0, 0, w, h, m, true)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, quality, out)
        if (bmp !== src) bmp.recycle()
        src.recycle()
        return out.toByteArray()
    }
}
