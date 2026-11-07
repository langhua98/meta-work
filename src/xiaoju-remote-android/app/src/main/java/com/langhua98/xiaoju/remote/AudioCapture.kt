package com.langhua98.xiaoju.remote

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder

/**
 * 直播的声音：AudioRecord 录单声道 16 位，每 100 ms 一包压成 μ-law 交给 onChunk(数据, 格式, 采集时间)。
 * 先试 16 kHz，不行退到 8 kHz（4.2 的手机都支持其中之一）。在自己的线程里跑，stop() 后结束。
 */
class AudioCapture(private val onChunk: (ByteArray, Int, Long) -> Unit) {
    @Volatile private var running = false
    private var thread: Thread? = null
    var error: String? = null
        private set

    fun start(): Boolean {
        for ((rate, codec) in listOf(16000 to StreamClient.AUDIO_ULAW_16K, 8000 to StreamClient.AUDIO_ULAW_8K)) {
            val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (min <= 0) continue
            val rec = try {
                AudioRecord(MediaRecorder.AudioSource.MIC, rate, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, maxOf(min, rate / 5 * 2))
            } catch (e: Exception) { continue }
            if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); continue }
            running = true
            thread = Thread({ loop(rec, rate, codec) }, "live-audio").apply { start() }
            return true
        }
        error = "麦克风打不开"
        return false
    }

    private fun loop(rec: AudioRecord, rate: Int, codec: Int) {
        val n = rate / 10  // 100 ms
        val buf = ShortArray(n)
        try {
            rec.startRecording()
            while (running) {
                var got = 0
                while (running && got < n) {
                    val r = rec.read(buf, got, n - got)
                    if (r <= 0) break
                    got += r
                }
                if (got <= 0) break
                // 这一包第一个样本大约是 got 个样本之前录的
                val ts = StreamClient.now() - got * 1000L / rate
                onChunk(Ulaw.encode(buf, got), codec, ts)
            }
        } catch (e: Exception) {
            error = e.message
        } finally {
            runCatching { rec.stop() }
            rec.release()
        }
    }

    fun stop() {
        running = false
        runCatching { thread?.join(1000) }
    }
}
