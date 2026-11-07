package com.langhua98.xiaoju.remote

import android.annotation.TargetApi
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import java.nio.ByteBuffer

/**
 * 手机自带的硬件 H.264 编码器（MediaCodec，Android 4.1+）。4.2 没有「从 Surface 喂画面」（4.3 才有），
 * 所以把相机的 NV21 换成编码器要的格式（NV12 或 I420）塞进输入缓冲区。
 * 同样的画质，数据量只有一帧帧 JPEG 的几分之一，网络慢时也能流畅。
 *
 * feed() 在相机线程上调；编出来的帧在自己的线程上交给 onFrame(Annex-B 数据, 是不是关键帧, 采集时间毫秒)。
 * 关键帧前面都带上 SPS/PPS，看的一端从任何一个关键帧都能开始解。
 */
@Suppress("DEPRECATION")
class H264Encoder(
    val width: Int, val height: Int, fps: Int, bitrate: Int,
    private val onFrame: (data: ByteArray, key: Boolean, tsMs: Long) -> Unit,
) {
    private val codec: MediaCodec
    private val semiPlanar: Boolean
    private val yuv = ByteArray(width * height * 3 / 2)
    private val inputs: Array<ByteBuffer>
    private var config: ByteArray? = null
    @Volatile private var running = true
    private val drain: Thread
    /** 编出来了几帧（看编码器是不是真的在工作） */
    @Volatile var produced = 0
        private set
    val name: String

    init {
        val (info, color) = pick() ?: throw IllegalStateException("这台手机没有硬件 H.264 编码器")
        name = info.name
        semiPlanar = color != MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar &&
            color != MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420PackedPlanar
        val f = MediaFormat.createVideoFormat(MIME, width, height)
        f.setInteger(MediaFormat.KEY_COLOR_FORMAT, color)
        f.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        f.setInteger(MediaFormat.KEY_FRAME_RATE, fps.coerceIn(1, 30))
        f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)   // 每秒一个关键帧：丢了帧最多卡 1 秒就接上
        codec = MediaCodec.createByCodecName(info.name)
        try {
            codec.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            inputs = codec.inputBuffers
        } catch (e: Throwable) {
            runCatching { codec.release() }
            throw e
        }
        drain = Thread({ drainLoop() }, "h264-out").apply { start() }
    }

    /** 塞一帧 NV21。编码器忙（等 waitUs 微秒还没有空的输入缓冲区）就丢这一帧，返回 false。 */
    fun feed(nv21: ByteArray, tsMs: Long, waitUs: Long = 0): Boolean {
        if (!running) return false
        val i = codec.dequeueInputBuffer(waitUs)
        if (i < 0) return false
        if (semiPlanar) H264.nv21ToNv12(nv21, yuv, width, height) else H264.nv21ToI420(nv21, yuv, width, height)
        val b = inputs[i]
        b.clear()
        if (b.capacity() < yuv.size) throw IllegalStateException("编码器输入缓冲区太小")
        b.put(yuv, 0, yuv.size)
        codec.queueInputBuffer(i, 0, yuv.size, tsMs * 1000, 0)
        return true
    }

    /** 马上出一个关键帧（Android 4.4+ 才支持；更老的等下一秒的关键帧）。 */
    fun requestKeyframe() {
        if (Build.VERSION.SDK_INT >= 19) runCatching { Sync19.request(codec) }
    }

    private fun drainLoop() {
        val info = MediaCodec.BufferInfo()
        var outs = try { codec.outputBuffers } catch (e: Throwable) { return }
        while (running) {
            val i = try { codec.dequeueOutputBuffer(info, 20_000) } catch (e: Throwable) { return }
            when {
                i == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> outs = codec.outputBuffers
                i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    // 有的编码器只在这里给 SPS/PPS（csd-0、csd-1），不单独出一个配置帧
                    val fmt = codec.outputFormat
                    val sps = fmt.bytes("csd-0")
                    val pps = fmt.bytes("csd-1")
                    if (sps != null && config == null) config = sps + (pps ?: ByteArray(0))
                }
                i >= 0 -> {
                    val b = outs[i]
                    b.position(info.offset)
                    b.limit(info.offset + info.size)
                    val data = ByteArray(info.size)
                    b.get(data)
                    runCatching { codec.releaseOutputBuffer(i, false) }
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) { config = data; continue }
                    if (data.isEmpty()) continue
                    val key = info.flags and MediaCodec.BUFFER_FLAG_SYNC_FRAME != 0 || H264.hasKeyframe(data)
                    val c = config
                    val out = if (key && c != null && !H264.startsWithSps(data)) c + data else data
                    produced++
                    try { onFrame(out, key, info.presentationTimeUs / 1000) } catch (e: Throwable) { }
                }
            }
        }
    }

    fun close() {
        running = false
        runCatching { drain.join(500) }
        runCatching { codec.stop() }
        runCatching { codec.release() }
    }

    private fun MediaFormat.bytes(key: String): ByteArray? {
        val b = (if (containsKey(key)) getByteBuffer(key) else null) ?: return null
        val d = b.duplicate()
        d.position(0)
        return ByteArray(d.remaining()).also { d.get(it) }
    }

    @TargetApi(19)
    private object Sync19 {
        fun request(c: MediaCodec) {
            c.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        }
    }

    companion object {
        const val MIME = "video/avc"
        private const val QCOM_NV12 = 0x7FA30C00   // 高通自己的 NV12（排布和标准 NV12 一样）

        /** 先挑硬件编码器（OMX.google / c2.android 是软件的，老手机上太慢），再挑能吃的颜色格式。 */
        private fun pick(): Pair<MediaCodecInfo, Int>? {
            val all = (0 until MediaCodecList.getCodecCount()).map { MediaCodecList.getCodecInfoAt(it) }
                .filter { it.isEncoder && it.supportedTypes.any { t -> t.equals(MIME, ignoreCase = true) } }
            val sorted = all.sortedBy { if (it.name.startsWith("OMX.google.") || it.name.startsWith("c2.android.")) 1 else 0 }
            for (info in sorted) {
                val colors = try { info.getCapabilitiesForType(MIME).colorFormats } catch (e: Throwable) { continue }
                val want = listOf(
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar,
                    QCOM_NV12,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420PackedSemiPlanar,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420PackedPlanar,
                )
                val c = want.firstOrNull { it in colors } ?: continue
                return info to c
            }
            return null
        }
    }
}
