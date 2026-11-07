package com.langhua98.xiaoju.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class MovWriterTest {

    private fun run(vararg cmd: String): String {
        val p = ProcessBuilder(*cmd).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        p.waitFor(60, TimeUnit.SECONDS)
        return out
    }

    private fun hasFfmpeg() = try { run("ffprobe", "-version").contains("ffprobe") } catch (e: Exception) { false }

    /** 用 ffmpeg 编一段真 H.264（每帧前有分隔符，关键帧前带 SPS/PPS，和手机编码器出来的一样），切成一帧帧。 */
    private fun frames(dir: File): List<ByteArray> {
        val f = File(dir, "src.h264")
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x480:rate=10",
            "-t", "3", "-c:v", "libx264", "-profile:v", "baseline", "-g", "10", "-bf", "0",
            "-x264-params", "aud=1:repeat-headers=1", f.path)
        val d = f.readBytes()
        val starts = (0 until d.size - 4).filter {
            d[it].toInt() == 0 && d[it + 1].toInt() == 0 && d[it + 2].toInt() == 0 && d[it + 3].toInt() == 1 && (d[it + 4].toInt() and 0x1f) == 9
        } + d.size
        return starts.zipWithNext { a, b -> d.copyOfRange(a, b) }
    }

    @Test fun realClipPlaysWithRotationAndSound() {
        assumeTrue("没有 ffmpeg，跳过", hasFfmpeg())
        val dir = Files.createTempDirectory("mov").toFile()
        val au = frames(dir)
        assertEquals(30, au.size)
        val (sps, pps) = MovWriter.params(au[0])!!
        val mov = File(dir, "event.mov")
        val w = MovWriter(mov, 640, 480, 90, sps, pps, 16000, t0 = 1000)
        au.forEachIndexed { i, f -> w.video(f, H264.hasKeyframe(f), 1000L + i * 100) }
        // 声音比画面晚 0.2 秒开始，中间丢了 0.2 秒（要补静音）
        val tone = ShortArray(640) { (Math.sin(it * 2 * Math.PI * 440 / 16000) * 8000).toInt().toShort() }
        var ts = 1200L
        while (ts < 3900) {
            if (ts !in 2000L until 2200L) w.audio(Ulaw.encode(tone, tone.size), ts)
            ts += 40
        }
        val dur = w.close()
        assertTrue("duration $dur", dur in 2900L..3100L)

        val info = run("ffprobe", "-v", "error", "-count_frames", "-show_entries",
            "stream=codec_name,width,height,sample_rate,nb_read_frames:stream_side_data=rotation:format=duration",
            "-of", "compact", mov.path)
        println(info)
        assertTrue(info, info.contains("codec_name=h264|width=640|height=480"))
        assertTrue(info, info.contains("nb_read_frames=30"))
        assertTrue(info, info.contains("rotation=-90"))          // ffprobe 的 -90 = 顺时针转 90 度显示
        assertTrue(info, info.contains("codec_name=pcm_mulaw|sample_rate=16000"))
        // 完整解一遍：画面和声音都没有错误
        assertEquals("", run("ffmpeg", "-hide_banner", "-v", "error", "-i", mov.path, "-f", "null", "-").trim())
        // 声音的长度 = 2.7 秒（含补的静音），开始时间 0.2 秒
        val a = run("ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=start_time,duration",
            "-of", "compact", mov.path)
        println(a)
        assertTrue(a, Regex("start_time=0\\.2").containsMatchIn(a))
        assertTrue(a, Regex("duration=2\\.(6|7)").containsMatchIn(a))
        System.getenv("MOV_KEEP")?.let { mov.copyTo(File(it), overwrite = true) }
    }

    @Test fun splitAndParams() {
        val k = byteArrayOf(0, 0, 0, 1, 9, 0x10, 0, 0, 0, 1, 0x67, 0x42, 0, 0x1e, 0, 0, 1, 0x68, 1, 0, 0, 1, 0x65, 5, 0)
        val n = MovWriter.splitNals(k)
        assertEquals(listOf(9, 7, 8, 5), n.map { it[0].toInt() and 0x1f })
        assertEquals(listOf(0x65, 5), n[3].map { it.toInt() })   // 末尾的 0 不算
        val (sps, pps) = MovWriter.params(k)!!
        assertEquals(0x67, sps[0].toInt())
        assertEquals(0x68, pps[0].toInt())
        assertEquals(null, MovWriter.params(byteArrayOf(0, 0, 1, 0x41, 1)))
    }
}
