package com.langhua98.xiaoju.remote

/**
 * 控制相机把哪几帧交给我们（底层省电）。
 *
 * 老相机（android.hardware.Camera）的预览回调要我们先给它一块空缓冲区，它才把一帧拷进来、叫醒 Java；
 * 手里没有空缓冲区时，这一帧在驱动里直接丢掉：不拷贝、不叫醒 Java。
 * 以前 3 块缓冲区一直轮着给：相机每秒出 30 帧，我们只用 10 帧，另外 20 帧（640×480 一帧 460 KB）白拷。
 * 现在相机手里最多只有一块缓冲区，而且只在下一帧快该用的时候（提前 LEAD 毫秒）才给，中间的帧都不拷。
 *
 * 只在相机的回调线程上用（不加锁）。不碰安卓的类，可以在电脑上测。
 */
class FramePacer {
    private var nextAt = 0L

    /** 这一帧（now 毫秒到的）要不要用：按节拍抽，平均下来正好是 fps。 */
    fun due(now: Long, fps: Int): Boolean {
        val gap = 1000L / fps.coerceIn(1, 60)
        if (now < nextAt - LEAD) return false
        nextAt = if (now - nextAt > gap) now + gap else nextAt + gap
        return true
    }

    /** 处理完这一帧（now）以后，再过多少毫秒把缓冲区还给相机。0 = 马上还。 */
    fun returnDelay(now: Long): Long = maxOf(0L, nextAt - LEAD - now)

    companion object {
        /** 提前多少毫秒把缓冲区给相机（相机一帧的间隔里总会有一帧落进来，不会错过太多） */
        const val LEAD = 30L
    }
}

/**
 * 省电侦测「守望」时留下的最近几帧（原始 NV21），有动静开始录像时先喂给编码器，
 * 录像就能从动静前一两秒开始（每秒 4 帧，比一直开着编码器省电得多）。
 * 缓冲区重复用，不每帧分配内存；最多 maxBytes。只在相机线程上用。
 */
class PreRoll(private val maxBytes: Long = 8L shl 20) {
    class Frame(var data: ByteArray, var w: Int, var h: Int, var ts: Long)

    private val frames = ArrayDeque<Frame>()
    private val spare = ArrayList<Frame>()
    @Volatile var windowMs = 2_000L

    val size get() = frames.size

    /** 留一份这一帧（拷贝）。比 windowMs 早的、超出内存上限的都扔掉。 */
    fun add(nv21: ByteArray, w: Int, h: Int, ts: Long) {
        if (windowMs <= 0) { clear(); return }
        val n = w * h * 3 / 2
        if (n <= 0 || nv21.size < n) return
        val cap = (maxBytes / n).toInt().coerceAtLeast(1)
        while (frames.isNotEmpty() && (frames.size >= cap || frames.first().ts < ts - windowMs)) spare += frames.removeFirst()
        val f = spare.removeLastOrNull()?.also { if (it.data.size != n) it.data = ByteArray(n) } ?: Frame(ByteArray(n), w, h, ts)
        System.arraycopy(nv21, 0, f.data, 0, n)
        f.w = w; f.h = h; f.ts = ts
        frames.addLast(f)
    }

    /** 从早到晚交出留着的帧（只交和现在画面一样大的），交完清空。 */
    fun drain(w: Int, h: Int, use: (Frame) -> Unit) {
        for (f in frames) if (f.w == w && f.h == h) use(f)
        clear()
    }

    fun clear() { spare.addAll(frames); frames.clear() }
}
