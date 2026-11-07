package com.langhua98.xiaoju.remote

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import java.io.ByteArrayOutputStream

/**
 * 直播画面：把相机的一帧帧 NV21 变成要发的消息。
 * 设置是 h264 时用手机的硬件 H.264 编码器；编码器没有、出错、或者 3 秒都不出数据，就自动退回 JPEG（不断流）。
 * frame() 只在相机线程上调；H.264 编出来的帧在编码器的线程上直接发。
 */
class LiveVideo(private val s: LiveSettings, private val av: Boolean, private val client: StreamClient) {
    @Volatile private var enc: H264Encoder? = null
    private var encConf = ""
    private var encSince = 0L
    private var fed = 0
    @Volatile private var rot = 0
    @Volatile private var askKeyAt = 0L
    private val jpg = ByteArrayOutputStream(64 * 1024)

    fun frame(nv21: ByteArray, w: Int, h: Int, rot: Int, ts: Long) {
        this.rot = rot
        if (client.subs <= 0) return   // 没人看就不编码，省电
        if (s.codec == LiveSettings.H264) {
            if (!H264.sizeOk(w, h)) { giveUp("这台手机的相机没有硬件编码合适的尺寸（${w}×$h）"); }
            else if (h264(nv21, w, h, ts)) return
        }
        jpeg(nv21, w, h, rot, ts)
    }

    private fun h264(nv21: ByteArray, w: Int, h: Int, ts: Long): Boolean {
        val rate = H264.bitrate(s.width, s.fps, s.quality)
        val conf = "${w}x$h/${s.fps}/$rate"
        try {
            if (enc == null || conf != encConf) {
                enc?.close()
                enc = null
                val e = H264Encoder(w, h, s.fps, rate) { data, key, t -> send(data, key, t) }
                enc = e; encConf = conf; encSince = System.currentTimeMillis(); fed = 0
                Bus.push("H.264 硬件编码：${e.name}，${w}×$h，${rate / 1000} kbps")
            }
            val e = enc ?: return false
            if (e.feed(nv21, ts)) fed++
            if (e.produced == 0 && fed > 5 && System.currentTimeMillis() - encSince > 3000) {
                giveUp("硬件编码器不出画面"); return false
            }
            return true
        } catch (t: Throwable) {
            giveUp("硬件编码出错：${t.message ?: t.javaClass.simpleName}")
            return false
        }
    }

    /** 编码器线程上：发一帧 H.264。丢过帧（网络跟不上 / 刚有人来看）要一个关键帧，免得等满 1 秒。 */
    private fun send(data: ByteArray, key: Boolean, ts: Long) {
        if (client.sendH264(StreamClient.h264(data, rot, ts, key), key, queueLimit())) return
        val now = System.currentTimeMillis()
        if (now - askKeyAt > 500) { askKeyAt = now; enc?.requestKeyframe() }
    }

    /** 网络跟不上时最多攒大约半秒的数据，再多就丢、等关键帧（延迟不越拖越长）。 */
    private fun queueLimit(): Long = maxOf(48L * 1024, H264.bitrate(s.width, s.fps, s.quality) / 8L / 2)

    private fun giveUp(why: String) {
        enc?.close(); enc = null; encConf = ""
        s.fallbackToJpeg()
        s.codecNote = "$why，已改用 JPEG"
        Bus.push(s.codecNote)
    }

    private fun jpeg(nv21: ByteArray, w: Int, h: Int, rot: Int, ts: Long) {
        try {
            jpg.reset()
            YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), s.quality, jpg)
            val b = jpg.toByteArray()
            client.send(if (av) StreamClient.frameTs(b, rot, ts) else StreamClient.frame(b, rot))
        } catch (e: Throwable) { /* 丢这一帧 */ }
    }

    fun close() {
        enc?.close(); enc = null
    }
}
