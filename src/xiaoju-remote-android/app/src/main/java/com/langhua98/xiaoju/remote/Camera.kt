package com.langhua98.xiaoju.remote

import android.annotation.TargetApi
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.graphics.YuvImage
import android.hardware.Camera as LegacyCamera
import java.io.ByteArrayOutputStream
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit


/**
 * 相机。用老的 android.hardware.Camera（Android 4.2 没有 Camera2），新系统上也能用。
 * 无预览拍照：给相机一个看不见的 SurfaceTexture 当预览目标。
 */
@Suppress("DEPRECATION")
object Camera {

    private fun findCamera(front: Boolean): Int {
        val want = if (front) LegacyCamera.CameraInfo.CAMERA_FACING_FRONT else LegacyCamera.CameraInfo.CAMERA_FACING_BACK
        val info = LegacyCamera.CameraInfo()
        for (i in 0 until LegacyCamera.getNumberOfCameras()) {
            LegacyCamera.getCameraInfo(i, info)
            if (info.facing == want) return i
        }
        return 0
    }

    /** 旧接口（即时信箱的旧直播用）：参数固定、有时长，一帧一张 JPEG。 */
    fun stream(front: Boolean, targetW: Int, quality: Int, fps: Int, durationMs: Long,
               running: () -> Boolean, onFrame: (jpg: ByteArray, rot: Int, ts: Long) -> Unit) {
        val end = System.currentTimeMillis() + durationMs
        val out = ByteArrayOutputStream(64 * 1024)
        live(LiveSettings(front, targetW, quality, fps), { running() && System.currentTimeMillis() < end }) { data, w, h, rot, ts ->
            out.reset()
            YuvImage(data, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), quality, out)
            onFrame(out.toByteArray(), rot, ts)
        }
    }

    /**
     * 实时画面：连续从预览里取帧（NV21），按 settings 的帧率交给 onFrame。阻塞调用，直到 running 变 false。
     * 用老相机的预览回调，4.2 也能跑。预览缓冲区是固定的几块轮着用（不每帧新分配内存，老手机上不会因为回收内存一顿一顿）；
     * onFrame 返回后这块缓冲区就还给相机了，要留数据得自己拷。
     * rot 是画面要顺时针旋转多少度才是正的，交给看的一端去转（省这台老手机的 CPU）。
     * 直播中改 settings：镜头/清晰度/编码会关掉相机重开，其他的当场生效。
     */
    fun live(s: LiveSettings, running: () -> Boolean,
             onFrame: (nv21: ByteArray, w: Int, h: Int, rot: Int, ts: Long) -> Unit) {
        if (LegacyCamera.getNumberOfCameras() == 0) throw IllegalStateException("这台手机没有摄像头")
        Torch.releaseLegacy()
        val ht = HandlerThread("vid").apply { start() }
        val h = Handler(ht.looper)
        try {
            while (running()) {
                val ver = s.version
                val front = s.front
                val ready = CountDownLatch(1)
                var startErr: Throwable? = null
                var cam: LegacyCamera? = null
                var tex: SurfaceTexture? = null
                h.post {
                    try {
                        val id = findCamera(front)
                        val c = LegacyCamera.open(id)
                        cam = c
                        val rot = LegacyCamera.CameraInfo().also { LegacyCamera.getCameraInfo(id, it) }.orientation
                        val p = c.parameters
                        val sz = LiveSettings.pickSize(p.supportedPreviewSizes.map { it.width to it.height },
                            s.width, s.codec == LiveSettings.H264)
                        sz?.let { p.setPreviewSize(it.first, it.second) }
                        p.previewFormat = ImageFormat.NV21
                        // 预览帧率开到最高（暗的时候相机自己会降），抽帧才均匀
                        p.supportedPreviewFpsRange?.maxWithOrNull(compareBy<IntArray>({ it[1] }, { -it[0] }))
                            ?.let { p.setPreviewFpsRange(it[0], it[1]) }
                        val modes = p.supportedFocusModes ?: emptyList()
                        if ("continuous-video" in modes) p.focusMode = "continuous-video"
                        else if ("continuous-picture" in modes) p.focusMode = "continuous-picture"
                        try { c.parameters = p } catch (e: RuntimeException) {
                            // 有的手机不接受这个帧率范围：去掉再试
                            val q = c.parameters
                            sz?.let { q.setPreviewSize(it.first, it.second) }
                            q.previewFormat = ImageFormat.NV21
                            c.parameters = q
                        }
                        tweak(c, s, front)
                        val fw = c.parameters.previewSize.width
                        val fh = c.parameters.previewSize.height
                        val t = SurfaceTexture(20); tex = t
                        c.setPreviewTexture(t)
                        val size = fw * fh * ImageFormat.getBitsPerPixel(ImageFormat.NV21) / 8
                        repeat(3) { c.addCallbackBuffer(ByteArray(size)) }
                        var nextAt = 0L
                        c.setPreviewCallbackWithBuffer { data, camera ->
                            if (data == null) return@setPreviewCallbackWithBuffer
                            val now = System.currentTimeMillis()
                            val gap = 1000L / s.fps
                            if (now >= nextAt && running()) {
                                // 按节拍抽帧：平均下来正好是设的帧率（不会因为相机 30 帧/秒的间隔凑不齐而变少）
                                nextAt = if (now - nextAt > gap) now + gap else nextAt + gap
                                val ts = StreamClient.now()   // 采集时间（和声音同一个时钟）
                                try { onFrame(data, fw, fh, rot, ts) } catch (e: Throwable) { /* 丢这一帧 */ }
                            }
                            camera.addCallbackBuffer(data)
                        }
                        c.startPreview()
                    } catch (e: Throwable) { startErr = e } finally { ready.countDown() }
                }
                ready.await(8, TimeUnit.SECONDS)
                startErr?.let { e ->
                    val done = CountDownLatch(1)
                    h.post { cleanup(cam, tex); done.countDown() }
                    done.await(3, TimeUnit.SECONDS)
                    throw e
                }
                var tw = s.tweak
                while (running() && s.version == ver) {
                    if (s.tweak != tw) { tw = s.tweak; h.post { cam?.let { runCatching { tweak(it, s, front) } } } }
                    try { Thread.sleep(100) } catch (e: InterruptedException) { break }
                }
                // 关掉这台相机（换镜头/清晰度时接着开新的）
                val closed = CountDownLatch(1)
                h.post { runCatching { cam?.setPreviewCallbackWithBuffer(null) }; cleanup(cam, tex); closed.countDown() }
                closed.await(3, TimeUnit.SECONDS)
            }
        } finally {
            ht.quit()
        }
    }

    /** 在开着的相机上设亮度、变焦、手电；不支持的记到 s.unsupported。 */
    private fun tweak(c: LegacyCamera, s: LiveSettings, front: Boolean) {
        val p = c.parameters
        val no = ArrayList<String>()
        val min = p.minExposureCompensation
        val max = p.maxExposureCompensation
        if (min != 0 || max != 0) p.exposureCompensation = LiveSettings.exposureIndex(s.exposure, min, max)
        else if (s.exposure != 0f) no += "调亮度"
        if (p.isZoomSupported) p.zoom = Math.round(s.zoom * p.maxZoom)
        else if (s.zoom > 0f) no += "变焦"
        val flash = p.supportedFlashModes ?: emptyList()
        if (s.torch && !front && "torch" in flash) p.flashMode = "torch"
        else {
            if (s.torch) no += if (front) "前置镜头开手电" else "手电"
            if ("off" in flash) p.flashMode = "off"
        }
        c.parameters = p
        s.unsupported = if (no.isEmpty()) "" else "这台手机不支持" + no.joinToString("、")
    }

    private fun cleanup(cam: LegacyCamera?, tex: SurfaceTexture?) {
        runCatching { cam?.stopPreview() }
        runCatching { cam?.release() }
        runCatching { tex?.release() }
    }

    /** 拍一张 JPEG。阻塞调用，不要在主线程上调。 */
    fun capture(front: Boolean, timeoutMs: Long = 15_000): ByteArray {
        if (LegacyCamera.getNumberOfCameras() == 0) throw IllegalStateException("这台手机没有摄像头")
        Torch.releaseLegacy()   // 老接口开着手电时相机被占用，先关掉
        val ht = HandlerThread("cam").apply { start() }
        val h = Handler(ht.looper)
        val latch = CountDownLatch(1)
        var result: ByteArray? = null
        var error: Throwable? = null
        var cam: LegacyCamera? = null
        var tex: SurfaceTexture? = null

        h.post {
            try {
                val id = findCamera(front)
                val c = LegacyCamera.open(id)
                cam = c
                val info = LegacyCamera.CameraInfo().also { LegacyCamera.getCameraInfo(id, it) }
                val p = c.parameters
                // 选不超过 1920 的最大尺寸，传得快一点
                val size = p.supportedPictureSizes
                    .filter { maxOf(it.width, it.height) <= 1920 }
                    .maxByOrNull { it.width * it.height }
                    ?: p.supportedPictureSizes.minByOrNull { it.width * it.height }
                size?.let { p.setPictureSize(it.width, it.height) }
                p.pictureFormat = ImageFormat.JPEG
                p.jpegQuality = 85
                p.setRotation(info.orientation)   // 竖着拿手机时照片方向正确
                val modes = p.supportedFocusModes ?: emptyList()
                when {
                    "continuous-picture" in modes -> p.focusMode = "continuous-picture"
                    "auto" in modes -> p.focusMode = "auto"
                }
                c.parameters = p
                val t = SurfaceTexture(10)
                tex = t
                c.setPreviewTexture(t)
                c.startPreview()
                // 给自动曝光一点时间
                h.postDelayed({
                    try {
                        c.takePicture(null, null) { data, _ -> result = data; latch.countDown() }
                    } catch (e: Throwable) { error = e; latch.countDown() }
                }, 900)
            } catch (e: Throwable) { error = e; latch.countDown() }
        }

        val done = latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        h.post {
            runCatching { cam?.stopPreview() }
            runCatching { cam?.release() }
            runCatching { tex?.release() }
            ht.quit()
        }
        if (!done) throw IllegalStateException("拍照超时")
        error?.let { throw it }
        return result ?: throw IllegalStateException("没拿到照片数据")
    }
}

/** 手电筒：Android 6.0+ 用 CameraManager.setTorchMode，更老的用老相机接口的常亮闪光灯。 */
@Suppress("DEPRECATION")
object Torch {
    private var legacy: LegacyCamera? = null
    private var legacyTex: SurfaceTexture? = null

    fun set(ctx: Context, on: Boolean): String {
        if (Build.VERSION.SDK_INT >= 23) return Torch23.set(ctx, on)
        if (!on) { releaseLegacy(); return "手电筒已关闭" }
        if (legacy != null) return "手电筒已打开"
        val c = LegacyCamera.open()  ?: return "这台手机没有后置摄像头"
        val p = c.parameters
        val modes = p.supportedFlashModes ?: emptyList()
        if ("torch" !in modes) { c.release(); return "这台手机不支持手电筒常亮" }
        p.flashMode = "torch"
        c.parameters = p
        val t = SurfaceTexture(11)
        c.setPreviewTexture(t)
        c.startPreview()
        legacy = c; legacyTex = t
        return "手电筒已打开"
    }

    fun releaseLegacy() {
        legacy?.let { c ->
            runCatching { val p = c.parameters; p.flashMode = "off"; c.parameters = p }
            runCatching { c.stopPreview() }
            runCatching { c.release() }
        }
        runCatching { legacyTex?.release() }
        legacy = null; legacyTex = null
    }
}

@TargetApi(23)
private object Torch23 {
    fun set(ctx: Context, on: Boolean): String {
        val mgr = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = mgr.cameraIdList.firstOrNull {
            mgr.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return "这台手机没有闪光灯"
        mgr.setTorchMode(id, on)
        return "手电筒已${if (on) "打开" else "关闭"}"
    }
}
