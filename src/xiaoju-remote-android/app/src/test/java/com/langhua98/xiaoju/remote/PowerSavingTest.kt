package com.langhua98.xiaoju.remote

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject

/** 省电（0.14）：相机缓冲区节拍、传感器帧率档、守望留帧、电流读数、设置。 */
class PowerSavingTest {
    /**
     * 模拟相机：每 interval 毫秒出一帧，手里有空缓冲区才拷进来交给我们（copies 加 1），
     * 我们处理完按 FramePacer 说的时间再还缓冲区。返回 (拷了几帧, 用了几帧)。
     */
    private fun simulate(sensorFps: Int, want: Int, seconds: Int, workMs: Long = 5): Pair<Int, Int> {
        val p = FramePacer()
        val interval = 1000.0 / sensorFps
        var bufferAt = 0L          // 什么时候缓冲区回到相机手里
        var copies = 0
        var used = 0
        var k = 0
        while (true) {
            val t = Math.round(k++ * interval)
            if (t >= seconds * 1000L) break
            if (t < bufferAt) continue          // 相机手里没缓冲区：驱动里丢掉，不拷贝
            copies++
            val done = if (p.due(t, want)) { used++; t + workMs } else t
            bufferAt = done + p.returnDelay(done)
        }
        return copies to used
    }

    @Test fun cameraOnlyCopiesFramesWeUse() {
        // 以前：相机 30 帧/秒全拷进来，只用 10 帧
        val (copies, used) = simulate(30, 10, 60)
        assertTrue("用的帧数 $used", used in 590..610)
        assertTrue("拷贝 $copies 帧，应该和用的差不多", copies <= used * 1.15)
    }

    @Test fun watchModeFourFramesPerSecond() {
        val (copies, used) = simulate(15, LiveSettings.WATCH_FPS, 60)
        assertTrue("守望每秒 4 帧，用了 $used", used in 230..245)
        assertTrue("拷贝 $copies", copies <= used * 1.15)
    }

    @Test fun keepsUpWhenSensorIsSlowerThanWanted() {
        val (copies, used) = simulate(15, 15, 10)
        assertTrue("相机 15 帧、要 15 帧：用了 $used", used >= 145)
        assertEquals(copies, used)
    }

    @Test fun pickFpsRangeChoosesLowestThatIsEnough() {
        val s4 = listOf(intArrayOf(7500, 30000), intArrayOf(15000, 15000), intArrayOf(15000, 30000), intArrayOf(24000, 24000), intArrayOf(30000, 30000))
        // 录像 / 直播（10 帧）：够 15 就行，不用 30
        assertArrayEquals(intArrayOf(15000, 15000), LiveSettings.pickFpsRange(s4, 10, false))
        // 守望：最高帧率够用的里面最低那档
        assertArrayEquals(intArrayOf(15000, 15000), LiveSettings.pickFpsRange(s4, 4, true))
        val withLow = s4 + listOf(intArrayOf(5000, 10000), intArrayOf(7500, 10000))
        assertArrayEquals(intArrayOf(5000, 10000), LiveSettings.pickFpsRange(withLow, 4, true))
        // 只有 30 帧的档：只能选它，最低帧率不低于 15 的优先
        val only30 = listOf(intArrayOf(7500, 30000), intArrayOf(15000, 30000))
        assertArrayEquals(intArrayOf(15000, 30000), LiveSettings.pickFpsRange(only30, 10, false))
        // 都不够：选最高的
        assertArrayEquals(intArrayOf(10000, 12000), LiveSettings.pickFpsRange(listOf(intArrayOf(10000, 12000), intArrayOf(5000, 8000)), 15, false))
        assertNull(LiveSettings.pickFpsRange(emptyList()))
    }

    @Test fun watchSwitchBumpsProfileOnlyOnChange() {
        val s = LiveSettings(false, 640, 50, 10, LiveSettings.H264)
        val p0 = s.profile
        s.setWatch(false); assertEquals(p0, s.profile)
        s.setWatch(true); assertEquals(p0 + 1, s.profile); assertEquals(LiveSettings.WATCH_FPS, s.frameFps)
        s.setWatch(true); assertEquals(p0 + 1, s.profile)
        s.setWatch(false); assertEquals(10, s.frameFps)
        val v = s.version
        s.setWatch(true); assertEquals("换帧率档不重开相机", v, s.version)
    }

    @Test fun preRollKeepsRecentFramesWithinWindowAndMemory() {
        val w = 64; val h = 48; val n = w * h * 3 / 2
        val pr = PreRoll(maxBytes = n * 5L)
        pr.windowMs = 2_000
        for (i in 0 until 20) pr.add(ByteArray(n) { i.toByte() }, w, h, i * 250L)   // 每秒 4 帧，5 秒
        assertEquals("内存上限 5 帧", 5, pr.size)
        val got = ArrayList<Long>()
        pr.drain(w, h) { f -> got += f.ts; assertEquals((f.ts / 250).toInt().toByte(), f.data[0]) }
        assertEquals(listOf(3750L, 4000L, 4250L, 4500L, 4750L), got)
        assertEquals(0, pr.size)
        // 时间窗口：2 秒以前的扔掉
        val big = PreRoll()
        big.windowMs = 1_000
        for (i in 0 until 20) big.add(ByteArray(n), w, h, i * 250L)
        assertTrue(big.size in 4..5)
        // 换了分辨率的不交出来
        big.drain(32, 24) { throw AssertionError("尺寸不对的不该交出来") }
        // 窗口 0 = 不留
        big.windowMs = 0
        big.add(ByteArray(n), w, h, 0); assertEquals(0, big.size)
    }

    @Test fun powerMeterUnits() {
        assertEquals(350, PowerMeter.toMa("350\n"))
        assertEquals(350, PowerMeter.toMa("-350"))
        assertEquals(412, PowerMeter.toMa("412345"))      // 微安
        assertEquals(412, PowerMeter.toMa("-412345"))
        assertNull(PowerMeter.toMa("abc"))
    }

    @Test fun fixedCurrentReadingIsRejected() {
        // S4：一直是 1900（充电电流设定值，不是实测）
        assertTrue(PowerMeter.looksFixed(listOf(1900, 1900, 1900, 1900, 1900), -1, 0))
        // 真的电流会跳
        assertFalse(PowerMeter.looksFixed(listOf(412, 398, 455, 401, 420), -1, 0))
        // 一次读数刚好一样、又不是整百：先不下结论；隔 10 秒以上还是这个数才算
        assertFalse(PowerMeter.looksFixed(listOf(417, 417, 417), -1, 0))
        assertFalse(PowerMeter.looksFixed(listOf(417, 417, 417), 417, 3_000))
        assertTrue(PowerMeter.looksFixed(listOf(417, 417, 417), 417, 15_000))
        assertFalse("太少不判", PowerMeter.looksFixed(listOf(1900, 1900), -1, 0))
    }

    @Test fun ecoIsOnByDefaultAndPreRollCapped() {
        val m = MonitorConfig()
        assertTrue(m.eco)
        assertEquals(3_000L, m.ecoPreMs)               // pre = 5，省电时最多 3 秒
        val off = m.merge(JSONObject().put("eco", false).put("pre", 2))
        assertFalse(off.eco); assertEquals(2_000L, off.ecoPreMs)
        assertFalse(MonitorConfig.fromJson(off.toJson().toString()).eco)
        assertTrue("老设置里没有 eco：默认省电", MonitorConfig.fromJson("{\"on\":true}").eco)
    }
}
