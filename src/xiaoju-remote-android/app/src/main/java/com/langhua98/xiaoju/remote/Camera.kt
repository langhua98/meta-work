package com.langhua98.xiaoju.remote

import android.annotation.TargetApi
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.Camera as LegacyCamera
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
