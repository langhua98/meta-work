package com.langhua98.xiaoju.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class CommandLanesTest {
    @Test fun slowCommandDoesNotBlockQuickOnes() {
        val l = CommandLanes(slowThreads = 2)
        val release = CountDownLatch(1)
        val quickDone = CountDownLatch(3)
        // 两条慢的占满慢线（比如测速、录音）
        l.submit("s1", fast = false) { release.await() }
        l.submit("s2", fast = false) { release.await() }
        // 快的照样马上做完
        repeat(3) { i -> l.submit("q$i", fast = true) { quickDone.countDown() } }
        assertTrue("quick commands waited for slow ones", quickDone.await(2, TimeUnit.SECONDS))
        assertTrue(l.running("s1"))
        release.countDown()
        l.shutdown()
    }

    @Test fun slowCommandsRunSideBySide() {
        val l = CommandLanes(slowThreads = 3)
        val started = CountDownLatch(3)
        val release = CountDownLatch(1)
        repeat(3) { i -> l.submit("s$i", fast = false) { started.countDown(); release.await() } }
        assertTrue("slow commands should not run one by one", started.await(2, TimeUnit.SECONDS))
        release.countDown()
        l.shutdown()
    }

    @Test fun sameCameraIsBusyNotQueued() {
        val l = CommandLanes()
        assertNull(l.take("camera", "拍照"))
        assertEquals("拍照", l.take("camera", "开手电"))   // 第二条马上知道相机在忙、谁在用
        assertNull(l.take("mic", "录音"))                 // 别的东西不受影响
        l.release("camera")
        assertNull(l.take("camera", "开手电"))
        l.shutdown()
    }

    @Test fun cancelInterruptsRunningCommand() {
        val l = CommandLanes()
        val started = CountDownLatch(1)
        val interrupted = AtomicBoolean(false)
        val finished = CountDownLatch(1)
        l.submit("bench", fast = false) {
            started.countDown()
            try { Thread.sleep(10_000) } catch (e: InterruptedException) { interrupted.set(true) }
            finished.countDown()
        }
        assertTrue(started.await(2, TimeUnit.SECONDS))
        assertTrue(l.cancel("bench"))
        assertTrue(finished.await(2, TimeUnit.SECONDS))
        assertTrue(interrupted.get())
        assertFalse("already finished: nothing to cancel", l.cancel("bench"))
        assertFalse(l.cancel("nope"))
        l.shutdown()
        assertFalse("after shutdown nothing is accepted", l.submit("x", fast = true) {})
    }
}
