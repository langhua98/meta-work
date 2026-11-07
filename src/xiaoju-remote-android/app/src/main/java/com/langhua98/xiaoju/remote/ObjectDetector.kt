package com.langhua98.xiaoju.remote

import android.content.Context

/**
 * 认出画面里动的是什么（人、猫、狗、车…80 种）：FastestDet 小模型（dog-qiuqiu，BSD），ncnn 跑在 C++ 里。
 * S4 上 1 个核大约 90 毫秒一张；只在有动静时跑，不影响录像和直播。
 * 识别是加在移动侦测上的：有东西动照样录、照样提醒，只是多写一句「有人」「有猫」，截图上框出来。
 */
object ObjectDetector {
    /** 一个认出来的东西：位置是 0…1，相机原始方向（要转正的话用 upright()） */
    class Detection(val cls: Int, val score: Float, val x1: Float, val y1: Float, val x2: Float, val y2: Float) {
        val name get() = NAMES.getOrElse(cls) { "东西" }
        val isPerson get() = cls == 0
        /** 会自己动的：人、交通工具、动物（椅子、电视这些一直在画面里的不算） */
        val canMove get() = cls in 0..8 || cls in 14..23
    }

    @Volatile private var state = 0   // 0 = 还没试过，1 = 能用，-1 = 用不了

    /** 有 C++ 库、模型也没读失败过（还没读也算能用：第一次有动静时才读） */
    val usable: Boolean get() = state >= 0 && NativeBench.available

    @JvmStatic private external fun nativeLoad(param: String, bin: ByteArray): Boolean
    @JvmStatic private external fun nativeDetect(nv21: ByteArray, w: Int, h: Int, thresh: Float): FloatArray?

    /** 第一次用时读模型（大约 0.5 MB）。用不了（没带 C++ 库、读不了）返回 false。 */
    @Synchronized fun ready(ctx: Context): Boolean {
        if (state != 0) return state > 0
        state = -1
        if (!NativeBench.available) return false
        try {
            val param = ctx.assets.open("models/fastestdet.param").bufferedReader().readText()
            val bin = ctx.assets.open("models/fastestdet.bin").readBytes()
            if (nativeLoad(param, bin)) state = 1
        } catch (e: Throwable) { }
        return state > 0
    }

    /** 认一帧 NV21（w×h）。用不了或出错返回空。 */
    fun detect(nv21: ByteArray, w: Int, h: Int, thresh: Float = 0.55f): List<Detection> {
        if (state <= 0) return emptyList()
        val r = try { nativeDetect(nv21, w, h, thresh) } catch (e: Throwable) { null } ?: return emptyList()
        return parse(r)
    }

    /** [类别, 分数, x1, y1, x2, y2] × n → Detection */
    fun parse(r: FloatArray): List<Detection> = (0 until r.size / 6).map { i ->
        val o = i * 6
        Detection(r[o].toInt(), r[o + 1], r[o + 2], r[o + 3], r[o + 4], r[o + 5])
    }

    /** 「人×2、猫」：人排最前，然后按个数从多到少，最多写 4 种 */
    fun summary(ds: List<Detection>): String = summaryOf(ds.groupingBy { it.cls }.eachCount())

    /** 类别 → 个数 的汇总写成一句话 */
    fun summaryOf(counts: Map<Int, Int>): String =
        counts.entries.sortedWith(compareBy({ if (it.key == 0) 0 else 1 }, { -it.value }))
            .take(4).joinToString("、") { (cls, n) -> NAMES.getOrElse(cls) { "东西" } + if (n > 1) "×$n" else "" }

    /** 相机原始方向的框 → 转正（顺时针 rot 度）以后的框 [x1, y1, x2, y2]，0…1 */
    fun upright(d: Detection, rot: Int): FloatArray {
        val a = MotionDetector.upright(d.x1, d.y1, rot)
        val b = MotionDetector.upright(d.x2, d.y2, rot)
        return floatArrayOf(minOf(a.first, b.first), minOf(a.second, b.second), maxOf(a.first, b.first), maxOf(a.second, b.second))
    }

    /** COCO 的 80 类，中文 */
    val NAMES = listOf(
        "人", "自行车", "汽车", "摩托车", "飞机", "公交车", "火车", "卡车", "船", "红绿灯",
        "消防栓", "停车牌", "停车计时器", "长椅", "鸟", "猫", "狗", "马", "羊", "牛",
        "大象", "熊", "斑马", "长颈鹿", "背包", "雨伞", "手提包", "领带", "行李箱", "飞盘",
        "滑雪板", "单板滑雪", "球", "风筝", "球棒", "棒球手套", "滑板", "冲浪板", "网球拍", "瓶子",
        "酒杯", "杯子", "叉子", "刀", "勺子", "碗", "香蕉", "苹果", "三明治", "橙子",
        "西兰花", "胡萝卜", "热狗", "披萨", "甜甜圈", "蛋糕", "椅子", "沙发", "盆栽", "床",
        "餐桌", "马桶", "电视", "笔记本电脑", "鼠标", "遥控器", "键盘", "手机", "微波炉", "烤箱",
        "烤面包机", "水槽", "冰箱", "书", "钟", "花瓶", "剪刀", "泰迪熊", "吹风机", "牙刷",
    )
}
