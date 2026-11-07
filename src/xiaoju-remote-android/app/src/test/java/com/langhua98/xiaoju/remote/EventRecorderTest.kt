package com.langhua98.xiaoju.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class EventRecorderTest {
    private fun run(vararg cmd: String): String {
        val p = ProcessBuilder(*cmd).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        p.waitFor(60, TimeUnit.SECONDS)
        return out
    }
    private fun hasFfmpeg() = try { run("ffprobe", "-version").contains("ffprobe") } catch (e: Exception) { false }

    /** 3 秒、10 帧/秒、每秒一个关键帧的真 H.264（30 帧，循环着用就是一直在出的码流） */
    private fun gop(dir: File): List<ByteArray> {
        val f = File(dir, "src.h264")
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x480:rate=10",
            "-t", "3", "-c:v", "libx264", "-profile:v", "baseline", "-g", "10", "-keyint_min", "10", "-sc_threshold", "0",
            "-bf", "0", "-x264-params", "aud=1:repeat-headers=1", f.path)
        val d = f.readBytes()
        val starts = (0 until d.size - 4).filter {
            d[it].toInt() == 0 && d[it + 1].toInt() == 0 && d[it + 2].toInt() == 0 && d[it + 3].toInt() == 1 && (d[it + 4].toInt() and 0x1f) == 9
        } + d.size
        return starts.zipWithNext { a, b -> d.copyOfRange(a, b) }
    }

    private class Clock { var t = 0L }

    /** 从 from 推到 to（毫秒）：每 100 ms 一帧画面，每 40 ms 一包声音；motionAt 里的时间点报一次动静。 */
    private fun feed(r: EventRecorder, c: Clock, au: List<ByteArray>, from: Long, to: Long, motionAt: Set<Long> = emptySet(),
                     started: MutableList<Long> = ArrayList()) {
        val ulaw = ByteArray(640) { 0x7f }
        var t = from
        while (t < to) {
            c.t = t
            if (t % 100 == 0L) {
                val f = au[((t / 100) % au.size).toInt()]
                r.video(f, H264.hasKeyframe(f), t, 640, 480, 90)
            }
            if (t % 40 == 0L) r.audio(ulaw, 16000, t)
            if (t in motionAt && r.motion(t)) started += t
            r.tick()
            t += 20
        }
    }

    private fun frames(f: File) = Regex("nb_read_frames=(\\d+)").find(
        run("ffprobe", "-v", "error", "-count_frames", "-select_streams", "v", "-show_entries", "stream=nb_read_frames", "-of", "compact", f.path)
    )?.groupValues?.get(1)?.toInt() ?: -1

    @Test fun preRollAndPostRoll() {
        assumeTrue(hasFfmpeg())
        val dir = Files.createTempDirectory("ev").toFile()
        val au = gop(dir)
        val store = EventStore(File(dir, "events"))
        val c = Clock()
        val r = EventRecorder(store, clock = { c.t }, wall = { 1_700_000_000_000L + c.t })
        r.preMs = 2_000; r.postMs = 3_000
        val closed = ArrayList<EventInfo>()
        r.onClosed = { closed += it }
        val started = ArrayList<Long>()
        // 10 秒时有动静，11、12 秒又有（同一次事件），12 + 3 = 15 秒结束
        feed(r, c, au, 0, 20_000, setOf(10_000L, 11_000L, 12_000L), started)
        assertEquals(listOf(10_000L), started)
        assertEquals(1, closed.size)
        val e = closed[0]
        assertTrue(e.video)
        assertEquals(3, e.motions)
        val mov = store.mov(e.name)
        // 从 8 秒的关键帧开始（动静前 2 秒），到 15 秒：大约 70 帧
        val n = frames(mov)
        assertTrue("frames $n", n in 68..72)
        assertEquals("", run("ffmpeg", "-hide_banner", "-v", "error", "-i", mov.path, "-f", "null", "-").trim())
        assertTrue(run("ffprobe", "-v", "error", "-show_entries", "stream=codec_name", "-of", "csv", mov.path).contains("pcm_mulaw"))
        assertEquals(listOf(e.name), store.list().map { it.name })
        assertEquals(1_700_000_008_000L, e.at)   // 开始时间 = 8 秒那个关键帧
        System.getenv("EVENT_KEEP")?.let { mov.copyTo(File(it), overwrite = true) }
    }

    @Test fun longEventIsSplitAtKeyframes() {
        assumeTrue(hasFfmpeg())
        val dir = Files.createTempDirectory("ev").toFile()
        val au = gop(dir)
        val store = EventStore(File(dir, "events"))
        val c = Clock()
        val r = EventRecorder(store, clock = { c.t }, wall = { 1_700_000_000_000L + c.t })
        r.preMs = 1_000; r.postMs = 2_000; r.maxMs = 5_000
        val closed = ArrayList<EventInfo>()
        r.onClosed = { closed += it }
        // 5 秒到 17 秒一直有动静
        feed(r, c, au, 0, 25_000, (5_000L..17_000L step 500).toSet())
        assertTrue("segments ${closed.size}", closed.size in 3..4)
        for (e in closed) {
            val mov = store.mov(e.name)
            assertEquals("", run("ffmpeg", "-hide_banner", "-v", "error", "-i", mov.path, "-f", "null", "-").trim())
            assertTrue("${e.name}: ${e.durMs}", e.durMs in 1_000L..5_200L)
        }
        assertEquals(closed.size, closed.map { it.name }.toSet().size)
    }

    @Test fun withoutVideoOnlySnapshotEvent() {
        val dir = Files.createTempDirectory("ev").toFile()
        val store = EventStore(File(dir, "events"))
        val c = Clock()
        val r = EventRecorder(store, clock = { c.t }, wall = { 1_700_000_000_000L + c.t })
        r.postMs = 1_000
        val closed = ArrayList<EventInfo>()
        r.onClosed = { closed += it }
        c.t = 1_000
        assertTrue(r.motion(1_000))
        assertTrue(r.recording)
        val name = r.current!!.name
        c.t = 3_000; r.tick()
        assertTrue(r.recording)          // 还没到 结束 + 3 秒
        c.t = 5_100; r.tick()
        assertFalse(r.recording)
        assertEquals(1, closed.size)
        assertEquals(name, closed[0].name)
        assertFalse(closed[0].video)
        assertFalse(store.mov(name).exists())
    }

    @Test fun storeCleanupDeletesOldestUploadedFirst() {
        val dir = Files.createTempDirectory("st").toFile()
        val s = EventStore(dir, maxBytes = 2500, minFreeBytes = 0)
        for (i in 0 until 4) {
            val e = EventInfo("20261107-10000$i", 1000L + i, video = true)
            s.mov(e.name).writeBytes(ByteArray(1000))
            if (i == 1) e.uploaded = "/x"
            s.save(e)
        }
        assertEquals(listOf("20261107-100003", "20261107-100002", "20261107-100001", "20261107-100000"), s.list().map { it.name })
        assertEquals(listOf("20261107-100000", "20261107-100002", "20261107-100003"), s.pendingUpload().map { it.name })
        assertEquals(2, s.cleanup { Long.MAX_VALUE })
        // 先删备份过的 01，再删最旧的 00
        assertEquals(listOf("20261107-100003", "20261107-100002"), s.list().map { it.name })
        assertFalse(s.delete("../etc"))
        assertEquals(null, s.get("../x"))
        assertEquals("20261107-100003-2", s.newName(java.text.SimpleDateFormat("yyyyMMdd-HHmmss").parse("20261107-100003").time))
    }
}
