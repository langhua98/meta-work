package com.langhua98.xiaoju.remote

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException

/**
 * 指令怎么排：快的走单独一条线（一下就做完，不等慢的），慢的几个一起跑；
 * 记着每条还在做的指令（好取消），以及相机 / 麦克风这类东西现在谁在用。
 * 不碰安卓的类，可以在电脑上跑测试。
 */
class CommandLanes(slowThreads: Int = 3) {
    private val quick: ExecutorService = Executors.newSingleThreadExecutor()
    private val slow: ExecutorService = Executors.newFixedThreadPool(slowThreads)
    private val jobs = ConcurrentHashMap<String, Future<*>>()
    private val busy = ConcurrentHashMap<String, String>()

    /** 交给快线或慢线。服务已经停了返回 false。 */
    fun submit(id: String, fast: Boolean, task: () -> Unit): Boolean = try {
        jobs[id] = (if (fast) quick else slow).submit {
            try { task() } finally { jobs.remove(id) }
        }
        true
    } catch (e: RejectedExecutionException) { false }

    /** 打断一条还在做（或排着）的指令。返回 true = 取消了。 */
    fun cancel(id: String): Boolean = jobs[id]?.cancel(true) == true

    fun running(id: String) = jobs.containsKey(id)

    /** 占用一样东西（相机、麦克风…）。别人在用返回在用的那条是什么，自己占上了返回 null。 */
    fun take(resource: String, what: String): String? = busy.putIfAbsent(resource, what)

    fun release(resource: String) { busy.remove(resource) }

    fun shutdown() { quick.shutdownNow(); slow.shutdownNow() }
}
