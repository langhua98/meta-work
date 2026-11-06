package com.langhua98.xiaoju.remote

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/** 无预览抓一张照片（JPEG 字节）。front=true 用前摄。 */
object Camera {

    @SuppressLint("MissingPermission")
    suspend fun capture(ctx: Context, front: Boolean): ByteArray = suspendCancellableCoroutine { cont ->
        val mgr = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val want = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val camId = mgr.cameraIdList.firstOrNull {
            mgr.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == want
        } ?: mgr.cameraIdList.firstOrNull()
        if (camId == null) { cont.resumeWithException(IllegalStateException("没有摄像头")); return@suspendCancellableCoroutine }

        val thread = HandlerThread("cam").apply { start() }
        val handler = Handler(thread.looper)
        val reader = ImageReader.newInstance(1920, 1080, ImageFormat.JPEG, 1)
        var device: CameraDevice? = null
        var done = false

        fun finish(result: Result<ByteArray>) {
            if (done) return
            done = true
            runCatching { device?.close() }
            runCatching { reader.close() }
            thread.quitSafely()
            if (cont.isActive) result.fold({ cont.resume(it) }, { cont.resumeWithException(it) })
        }

        reader.setOnImageAvailableListener({ r ->
            val img = r.acquireLatestImage()
            try {
                val buf = img.planes[0].buffer
                val data = ByteArray(buf.remaining()); buf.get(data)
                finish(Result.success(data))
            } catch (e: Throwable) { finish(Result.failure(e)) } finally { img?.close() }
        }, handler)

        cont.invokeOnCancellation { finish(Result.failure(InterruptedException("取消"))) }

        mgr.openCamera(camId, object : CameraDevice.StateCallback() {
            override fun onOpened(cam: CameraDevice) {
                device = cam
                val req = cam.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                    addTarget(reader.surface)
                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                    set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                }
                @Suppress("DEPRECATION")
                cam.createCaptureSession(listOf(reader.surface), object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        // 给自动曝光/对焦一点时间
                        handler.postDelayed({
                            runCatching { session.capture(req.build(), null, handler) }
                                .onFailure { finish(Result.failure(it)) }
                        }, 600)
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) =
                        finish(Result.failure(IllegalStateException("相机会话失败")))
                }, handler)
            }
            override fun onDisconnected(cam: CameraDevice) = finish(Result.failure(IllegalStateException("相机断开")))
            override fun onError(cam: CameraDevice, error: Int) = finish(Result.failure(IllegalStateException("相机错误 $error")))
        }, handler)
    }
}
