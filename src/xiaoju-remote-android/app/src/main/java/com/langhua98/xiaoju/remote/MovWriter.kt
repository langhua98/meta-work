package com.langhua98.xiaoju.remote

import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile

/**
 * 把 H.264 画面（和 μ-law 声音）写成 QuickTime 视频（.mov），iPhone 直接能放、能存相册。
 * Android 4.2 没有 MediaMuxer（4.3 才有），所以自己写；格式照着 ffmpeg 写出来的 .mov。
 * 边录边写画面数据（mdat），close() 时在文件末尾写目录（moov）。没 close 的文件放不了。
 * 不碰安卓的类，可以在电脑上跑测试。
 *
 * @param rot 画面要顺时针转多少度才是正的（写进视频的显示方向，播放器自己转）
 * @param audioRate 声音采样率（μ-law 单声道），null = 没有声音
 * @param t0 视频从这个时间（毫秒，和 video/audio 的时间戳同一个时钟）算起
 */
class MovWriter(
    private val file: File, private val width: Int, private val height: Int, private val rot: Int,
    private val sps: ByteArray, private val pps: ByteArray, private val audioRate: Int?, private val t0: Long,
) {
    private val out = BufferedOutputStream(FileOutputStream(file), 64 * 1024)
    private var pos = 0L
    private val mdatAt: Long

    // 画面：每帧一块
    private val vOffsets = ArrayList<Long>()
    private val vSizes = ArrayList<Int>()
    private val vTimes = ArrayList<Long>()
    private val vKeys = ArrayList<Int>()   // 第几帧是关键帧（从 1 数）
    // 声音：每包一块，每个样本 1 字节
    private val aOffsets = ArrayList<Long>()
    private val aCounts = ArrayList<Int>()
    private var aSamples = 0L
    private var aStart = -1L          // 第一包声音的时间
    private var closed = false

    val frames get() = vSizes.size
    val bytes get() = pos

    init {
        write(box("ftyp", be32(QT) + be32(0x200) + be32(QT)))
        write(box("wide", ByteArray(0)))
        mdatAt = pos
        write(be32(0) + "mdat".toByteArray(Charsets.US_ASCII))   // 大小 close 时补
    }

    /** 写一帧画面（Annex-B）。SPS/PPS/分隔符不写进数据（放在目录里）。 */
    fun video(annexB: ByteArray, key: Boolean, ts: Long) {
        check(!closed)
        val nals = splitNals(annexB).filter { (it[0].toInt() and 0x1f) !in setOf(H264.NAL_SPS, H264.NAL_PPS, 9) }
        if (nals.isEmpty()) return
        val start = pos
        var size = 0
        for (n in nals) { write(be32(n.size)); write(n); size += 4 + n.size }
        vOffsets += start; vSizes += size; vTimes += ts - t0
        if (key) vKeys += vSizes.size
    }

    /** 写一包声音（μ-law，每个样本 1 字节）。中间断了（丢过包）补静音，声音和画面不会越错越开。 */
    fun audio(ulaw: ByteArray, ts: Long) {
        check(!closed)
        val rate = audioRate ?: return
        if (ulaw.isEmpty()) return
        if (aStart < 0) aStart = maxOf(ts, t0)
        val expected = aStart + aSamples * 1000 / rate
        val gap = (ts - expected) * rate / 1000
        if (gap > rate / 10) {   // 晚了 0.1 秒以上：补静音（μ-law 的 0xFF）
            val silence = ByteArray(minOf(gap, rate * 10L).toInt()) { 0xFF.toByte() }
            aOffsets += pos; aCounts += silence.size; aSamples += silence.size
            write(silence)
        }
        aOffsets += pos; aCounts += ulaw.size; aSamples += ulaw.size
        write(ulaw)
    }

    /** 写目录、关文件。返回时长（毫秒）。 */
    fun close(): Long {
        if (closed) return 0
        closed = true
        val vDur = videoDurations()
        val vTotal = vDur.sum()
        val aTotal = if (audioRate != null && aSamples > 0) aSamples * 1000 / audioRate else 0L
        val aOff = if (aStart >= 0) aStart - t0 else 0L
        val movieDur = maxOf(vTotal, aOff + aTotal)
        val mdatSize = pos - mdatAt
        var traks = trak(1, video = true, mediaDur = vTotal, timescale = 1000, offset = 0, stbl = videoStbl(vDur))
        if (audioRate != null && aSamples > 0)
            traks += trak(2, video = false, mediaDur = aSamples, timescale = audioRate, offset = aOff, stbl = audioStbl(audioRate))
        write(box("moov", mvhd(movieDur, if (aSamples > 0) 3 else 2) + traks))
        out.close()
        RandomAccessFile(file, "rw").use { it.seek(mdatAt); it.writeInt(mdatSize.toInt()) }
        return movieDur
    }

    /** 每帧多长（毫秒）：到下一帧的时间，最后一帧和前一帧一样长。 */
    private fun videoDurations(): LongArray {
        val n = vTimes.size
        val d = LongArray(n)
        for (i in 0 until n - 1) d[i] = maxOf(1L, vTimes[i + 1] - vTimes[i])
        if (n > 0) d[n - 1] = if (n > 1) d[n - 2] else 100L
        return d
    }

    // ---- 目录（moov） ----

    private fun mvhd(dur: Long, nextTrack: Int) = box("mvhd",
        be32(0) + be32(0) + be32(0) + be32(1000) + be32(dur.toInt()) + be32(0x10000) + be16(0x100) + ByteArray(10) +
            matrix(0) + ByteArray(24) + be32(nextTrack))

    private fun trak(id: Int, video: Boolean, mediaDur: Long, timescale: Int, offset: Long, stbl: ByteArray): ByteArray {
        val movieDur = mediaDur * 1000 / timescale
        val tkhd = box("tkhd", be32(3) + be32(0) + be32(0) + be32(id) + be32(0) + be32((offset + movieDur).toInt()) +
            ByteArray(8) + be16(0) + be16(if (video) 0 else 1) + be16(if (video) 0 else 0x100) + be16(0) +
            matrix(if (video) rot else 0) + be32(if (video) width shl 16 else 0) + be32(if (video) height shl 16 else 0))
        // 编辑表：声音比画面晚开始时，前面空一段
        val edits = ArrayList<ByteArray>()
        if (offset > 0) edits += be32(offset.toInt()) + be32(-1) + be32(0x10000)
        edits += be32(movieDur.toInt()) + be32(0) + be32(0x10000)
        val elst = box("elst", be32(0) + be32(edits.size) + edits[0] + (if (edits.size > 1) edits[1] else ByteArray(0)))
        val mdhd = box("mdhd", be32(0) + be32(0) + be32(0) + be32(timescale) + be32(mediaDur.toInt()) + be16(0x7fff) + be16(0))
        val hdlr = box("hdlr", be32(0) + ascii("mhlr") + ascii(if (video) "vide" else "soun") + ByteArray(12) +
            pascal(if (video) "VideoHandler" else "SoundHandler"))
        val head = if (video) box("vmhd", be32(1) + ByteArray(8)) else box("smhd", ByteArray(8))
        val dhlr = box("hdlr", be32(0) + ascii("dhlr") + ascii("url ") + ByteArray(12) + pascal("DataHandler"))
        val dinf = box("dinf", box("dref", be32(0) + be32(1) + box("url ", be32(1))))
        val minf = box("minf", head + dhlr + dinf + stbl)
        return box("trak", tkhd + box("edts", elst) + box("mdia", mdhd + hdlr + minf))
    }

    private fun videoStbl(dur: LongArray): ByteArray {
        val avcC = box("avcC", byteArrayOf(1, sps[1], sps[2], sps[3], 0xFF.toByte(), 0xE1.toByte()) +
            be16(sps.size) + sps + byteArrayOf(1) + be16(pps.size) + pps)
        val name = ByteArray(32).also { val n = "xiaoju h264".toByteArray(); it[0] = n.size.toByte(); System.arraycopy(n, 0, it, 1, n.size) }
        val avc1 = box("avc1", ByteArray(6) + be16(1) + be16(0) + be16(0) + be32(0) + be32(0x200) + be32(0x200) +
            be16(width) + be16(height) + be32(0x480000) + be32(0x480000) + be32(0) + be16(1) + name +
            be16(0x18) + be16(0xffff) + avcC)
        val stsd = box("stsd", be32(0) + be32(1) + avc1)
        // 时长按连续相同的合并
        val runs = ArrayList<Pair<Int, Long>>()
        for (d in dur) if (runs.isNotEmpty() && runs.last().second == d) runs[runs.size - 1] = runs.last().first + 1 to d else runs += 1 to d
        val stts = box("stts", be32(0) + be32(runs.size) + ints(runs.flatMap { listOf(it.first, it.second.toInt()) }))
        val stss = box("stss", be32(0) + be32(vKeys.size) + ints(vKeys))
        val stsc = box("stsc", be32(0) + be32(1) + be32(1) + be32(1) + be32(1))
        val stsz = box("stsz", be32(0) + be32(0) + be32(vSizes.size) + ints(vSizes))
        val stco = box("stco", be32(0) + be32(vOffsets.size) + ints(vOffsets.map { it.toInt() }))
        return box("stbl", stsd + stts + stss + stsc + stsz + stco)
    }

    private fun audioStbl(rate: Int): ByteArray {
        val ulaw = box("ulaw", ByteArray(6) + be16(1) + be16(0) + be16(0) + be32(0) +
            be16(1) + be16(16) + be16(0) + be16(0) + be32(rate shl 16))
        val stsd = box("stsd", be32(0) + be32(1) + ulaw)
        val stts = box("stts", be32(0) + be32(1) + be32(aSamples.toInt()) + be32(1))
        // 每块几个样本：连续一样的合并成一条
        val runs = ArrayList<Pair<Int, Int>>()   // 从第几块开始, 每块几个样本
        aCounts.forEachIndexed { i, c -> if (runs.isEmpty() || runs.last().second != c) runs += (i + 1) to c }
        val stsc = box("stsc", be32(0) + be32(runs.size) + ints(runs.flatMap { listOf(it.first, it.second, 1) }))
        val stsz = box("stsz", be32(0) + be32(1) + be32(aSamples.toInt()))
        val stco = box("stco", be32(0) + be32(aOffsets.size) + ints(aOffsets.map { it.toInt() }))
        return box("stbl", stsd + stts + stsc + stsz + stco)
    }

    /** QuickTime 的变换矩阵：顺时针转 rot 度（宽高是编码的宽高）。 */
    private fun matrix(rot: Int): ByteArray {
        val one = 0x10000; val w = 0x40000000
        val m = when ((rot % 360 + 360) % 360) {
            90 -> intArrayOf(0, one, 0, -one, 0, 0, height shl 16, 0, w)
            180 -> intArrayOf(-one, 0, 0, 0, -one, 0, width shl 16, height shl 16, w)
            270 -> intArrayOf(0, -one, 0, one, 0, 0, 0, width shl 16, w)
            else -> intArrayOf(one, 0, 0, 0, one, 0, 0, 0, w)
        }
        return ints(m.toList())
    }

    private fun write(b: ByteArray) { out.write(b); pos += b.size }

    companion object {
        private const val QT = 0x71742020   // "qt  "

        fun box(type: String, body: ByteArray): ByteArray = be32(8 + body.size) + ascii(type) + body
        private fun ascii(s: String) = s.toByteArray(Charsets.US_ASCII)
        private fun pascal(s: String) = byteArrayOf(s.length.toByte()) + ascii(s)
        fun be32(v: Int) = byteArrayOf((v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte())
        fun be16(v: Int) = byteArrayOf((v ushr 8).toByte(), v.toByte())
        private fun ints(l: List<Int>): ByteArray {
            val b = ByteArrayOutputStream(l.size * 4)
            val d = DataOutputStream(b)
            for (v in l) d.writeInt(v)
            return b.toByteArray()
        }

        /** Annex-B → 一个个 NAL（不含起始码）。 */
        fun splitNals(b: ByteArray): List<ByteArray> {
            val starts = ArrayList<Int>()
            var i = 0
            while (i + 2 < b.size) {
                if (b[i].toInt() == 0 && b[i + 1].toInt() == 0 && b[i + 2].toInt() == 1) { starts += i + 3; i += 3 } else i++
            }
            val out = ArrayList<ByteArray>()
            for ((k, s) in starts.withIndex()) {
                var e = if (k + 1 < starts.size) starts[k + 1] - 3 else b.size
                while (e > s && b[e - 1].toInt() == 0) e--
                if (e > s) out += b.copyOfRange(s, e)
            }
            return out
        }

        /** 从一个关键帧里取 SPS、PPS。 */
        fun params(annexB: ByteArray): Pair<ByteArray, ByteArray>? {
            val n = splitNals(annexB)
            val sps = n.firstOrNull { (it[0].toInt() and 0x1f) == H264.NAL_SPS } ?: return null
            val pps = n.firstOrNull { (it[0].toInt() and 0x1f) == H264.NAL_PPS } ?: return null
            return sps to pps
        }
    }
}
