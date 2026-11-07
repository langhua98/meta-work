package com.langhua98.xiaoju.remote

/**
 * G.711 μ-law：16 位声音压成 8 位，体积减半，电话就用它。编解码都很便宜，4.2 的老手机也不费劲。
 * 不碰安卓的类，电脑上能直接测（见 src/test）。
 */
object Ulaw {
    private const val BIAS = 0x84
    private const val CLIP = 32635

    fun encode(sample: Int): Byte {
        var s = sample
        val sign = if (s < 0) { s = -s; 0x80 } else 0
        if (s > CLIP) s = CLIP
        s += BIAS
        var exponent = 7
        var mask = 0x4000
        while (s and mask == 0 && exponent > 0) { exponent--; mask = mask shr 1 }
        val mantissa = (s shr (exponent + 3)) and 0x0F
        return (sign or (exponent shl 4) or mantissa).inv().toByte()
    }

    fun decode(b: Byte): Int {
        val u = b.toInt().inv() and 0xFF
        val exponent = (u shr 4) and 0x07
        val sample = (((u and 0x0F) shl 3) + BIAS shl exponent) - BIAS
        return if (u and 0x80 != 0) -sample else sample
    }

    /** 一段 16 位小端 PCM（n 个样本）→ μ-law */
    fun encode(pcm: ShortArray, n: Int): ByteArray = ByteArray(n) { encode(pcm[it].toInt()) }
}
