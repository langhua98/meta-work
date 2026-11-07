package com.langhua98.xiaoju.remote

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MonitorConfigTest {
    @Test fun mergeOnlyChangesGivenFields() {
        val a = MonitorConfig()
        assertFalse(a.on)
        val b = a.merge(JSONObject().put("on", true).put("sensitivity", 500).put("post", 1))
        assertTrue(b.on)
        assertEquals(100, b.sensitivity)       // 裁到 1…100
        assertEquals(3, b.postSec)             // 最少 3 秒
        assertEquals(a.preSec, b.preSec)       // 没给的不变
        assertEquals(a.notify, b.notify)
        val c = MonitorConfig.fromJson(b.toJson().toString())
        assertEquals(b.toJson().toString(), c.toJson().toString())
        assertEquals(MonitorConfig().toJson().toString(), MonitorConfig.fromJson("not json").toJson().toString())
    }

    @Test fun regionsAreClampedAndTinyOnesDropped() {
        val r = MonitorConfig.parseRegions(JSONArray("[[0.1,0.2,0.5,0.5],[0.9,0.9,0.5,0.5],[0,0,0.01,0.5],[1,2]]"))
        assertEquals(2, r.size)
        assertEquals(listOf(0.1f, 0.2f, 0.5f, 0.5f), r[0].toList())
        assertEquals(0.1f, r[1][2], 1e-4f)     // 0.9 + 0.5 超出画面：裁到 0.1
        val cfg = MonitorConfig().merge(JSONObject().put("regions", JSONArray("[[0,0,1,0.5]]")))
        assertEquals(1, cfg.regions.size)
        assertEquals(0, cfg.merge(JSONObject().put("regions", JSONArray())).regions.size)
        assertEquals("h264", cfg.cameraJson().getString("codec"))
    }
}
