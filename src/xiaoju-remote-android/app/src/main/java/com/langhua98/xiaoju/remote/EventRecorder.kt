package com.langhua98.xiaoju.remote

/**
 * 事件录像：编码器一直在出 H.264，这里一直在内存里留着最近 preMs 多一点的画面和声音（从关键帧开始留，
 * 500 kbps 时 6 秒大约 400 KB）。有动静时从「动静前 preMs 秒之前最近的那个关键帧」开始写文件，
 * 所以事件开始前那几秒也在里面，而且文件第一帧一定是关键帧，能正常播放。
 * 每次有动静都把结束时间往后推到 postMs 之后；一段最长 maxMs，再长就在下一个关键帧接着写新的一段。
 * 换了分辨率（编码器重开，SPS 变了）也在新的关键帧处切一段。
 *
 * 时间戳都是 StreamClient.now()（单调时钟，毫秒）。video / audio / motion / tick 可以在不同线程调。
 * 不碰安卓的类，可以在电脑上跑测试。
 */
class EventRecorder(
    private val store: EventStore,
    private val clock: () -> Long = { StreamClient.now() },
    private val wall: () -> Long = { System.currentTimeMillis() },
) {
    @Volatile var preMs = 5_000L
    @Volatile var postMs = 15_000L
    @Volatile var maxMs = 120_000L
    /** 一段写完了（在调用 video / tick 的线程上） */
    var onClosed: ((EventInfo) -> Unit)? = null
    /** 写文件出错（磁盘满了之类） */
    var onError: ((String) -> Unit)? = null

    private class Sample(val video: Boolean, val data: ByteArray, val key: Boolean, val ts: Long, val rate: Int = 0)

    private val ring = ArrayList<Sample>()
    private var ringBytes = 0L
    private var w = 0
    private var h = 0
    private var rot = 0
    private var audioRate = 0          // 最近的声音采样率，0 = 没有声音

    private var active = false         // 一次事件正在进行（有动静 → 最后一次动静后 postMs）
    private var seg: EventInfo? = null // 正在写的这一段
    private var writer: MovWriter? = null
    private var params: Pair<ByteArray, ByteArray>? = null
    private var segStart = 0L
    private var endAt = 0L
    private var waitKey = false        // 有动静了，但内存里还没有关键帧：等下一个关键帧开始写

    val recording: Boolean @Synchronized get() = active
    /** 正在写的这一段（motion() 返回 true 后取名字、存截图用） */
    val current: EventInfo? @Synchronized get() = seg

    @Synchronized fun video(annexB: ByteArray, key: Boolean, ts: Long, width: Int, height: Int, rotation: Int) {
        w = width; h = height; rot = rotation
        val s = Sample(true, annexB, key, ts)
        keep(s)
        if (!active) return
        if (ts > endAt) { endEvent(); return }
        val wr = writer
        if (wr == null) {
            if (waitKey && key) MovWriter.params(annexB)?.let { waitKey = false; startSeg(listOf(s), it) }
            return
        }
        val p = if (key) MovWriter.params(annexB) else null
        val old = params
        when {
            key && p != null && old != null && !same(p, old) -> { finishSeg(); startSeg(listOf(s), p) }
            // 太长了换一段；快结束了就不换（免得最后剩一小段）
            key && old != null && ts - segStart >= maxMs && endAt - ts > minOf(2_000L, postMs / 2) -> { finishSeg(); startSeg(listOf(s), p ?: old) }
            else -> write(wr, s)
        }
    }

    @Synchronized fun audio(ulaw: ByteArray, rate: Int, ts: Long) {
        audioRate = rate
        val s = Sample(false, ulaw, false, ts, rate)
        keep(s)
        writer?.let { write(it, s) }
    }

    /** 检测到动静。返回 true = 这是一次新的事件（该截图、发提醒了）。 */
    @Synchronized fun motion(ts: Long): Boolean {
        endAt = maxOf(endAt, ts + postMs)
        if (active) { seg?.let { it.motions++ }; return false }
        active = true
        // 从动静前 preMs 之前最近的关键帧开始；内存里留的不够就从最早的关键帧开始
        // 太旧的不要（省电侦测时编码器停过，内存里可能还剩上一次的画面）
        val keys = ring.indices.filter { ring[it].video && ring[it].key && ring[it].ts >= ts - preMs - 3_000 }
        val from = keys.lastOrNull { ring[it].ts <= ts - preMs } ?: keys.firstOrNull()
        val p = from?.let { MovWriter.params(ring[it].data) }
        if (from != null && p != null) startSeg(ring.subList(from, ring.size).toList(), p)
        else {
            seg = EventInfo(store.newName(toWall(ts)), toWall(ts))
            waitKey = true
        }
        return true
    }

    /** 省电侦测回到守望（编码器关了）：内存里留的旧画面、声音都不要了。 */
    @Synchronized fun dropBuffered() {
        if (active) return
        ring.clear(); ringBytes = 0
    }

    /** 定时调：画面停了（相机关了、编码器坏了）也要按时结束。 */
    @Synchronized fun tick() {
        if (active && clock() > endAt + 3_000) endEvent()
    }

    /** 不录了（关掉侦测、相机关了）：写完正在录的。 */
    @Synchronized fun close() {
        if (active) endEvent()
        ring.clear(); ringBytes = 0
    }

    private fun startSeg(samples: List<Sample>, p: Pair<ByteArray, ByteArray>) {
        val t0 = samples[0].ts
        // 等关键帧时先建好的那一段（截图已经用了它的名字）接着用；其他情况按这段开始的时间起名
        val info = seg?.takeIf { writer == null && !it.video } ?: EventInfo(store.newName(toWall(t0)), toWall(t0))
        seg = info
        try {
            val wr = MovWriter(store.mov(info.name), w, h, rot, p.first, p.second, audioRate.takeIf { it > 0 }, t0)
            writer = wr; params = p; segStart = t0; info.video = true
            for (s in samples) write(wr, s)
        } catch (e: Exception) {
            writer = null
            onError?.invoke("写录像出错：${e.message}")
        }
    }

    private fun write(wr: MovWriter, s: Sample) {
        if (writer !== wr) return
        try {
            if (s.video) wr.video(s.data, s.key, s.ts) else if (s.ts >= segStart) wr.audio(s.data, s.ts)
        } catch (e: Exception) {
            onError?.invoke("写录像出错：${e.message}")
            runCatching { wr.close() }
            writer = null
        }
    }

    /** 写完这一段：关文件、存信息。 */
    private fun finishSeg() {
        val e = seg ?: return
        seg = null
        val wr = writer
        writer = null; params = null
        if (wr != null) {
            try { e.durMs = wr.close() } catch (ex: Exception) { onError?.invoke("写录像出错：${ex.message}"); e.video = false }
        }
        if (!e.video) store.mov(e.name).delete()
        store.save(e)
        onClosed?.invoke(e)
    }

    private fun endEvent() {
        finishSeg()
        active = false; waitKey = false; endAt = 0
    }

    /** 内存里只留最近 preMs 多一点：去掉「比 preMs 前最近的关键帧」更早的东西。 */
    private fun keep(s: Sample) {
        ring.add(s); ringBytes += s.data.size
        if (!s.video || !s.key) {
            // 一直没有关键帧（编码器坏了）也别无限攒
            while (ringBytes > MAX_RING && ring.isNotEmpty()) ringBytes -= ring.removeAt(0).data.size
            return
        }
        val limit = s.ts - preMs
        var cut = -1
        for (i in ring.indices) {
            val r = ring[i]
            if (r.ts > limit) break
            if (r.video && r.key) cut = i
        }
        if (cut > 0) {
            for (i in 0 until cut) ringBytes -= ring[i].data.size
            ring.subList(0, cut).clear()
        }
        while (ringBytes > MAX_RING && ring.size > 1) ringBytes -= ring.removeAt(0).data.size
    }

    private fun toWall(ts: Long) = wall() - (clock() - ts)

    private fun same(a: Pair<ByteArray, ByteArray>, b: Pair<ByteArray, ByteArray>?) =
        b != null && a.first.contentEquals(b.first) && a.second.contentEquals(b.second)

    companion object {
        /** 内存里最多留多少（1280×720 高码率时 6 秒也不到这么多） */
        const val MAX_RING = 8L shl 20
    }
}
