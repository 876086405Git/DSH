package io.github.ccch1mneyyy.dsh_app.voice

import android.content.Context
import android.content.res.AssetManager
import android.util.Log
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.OfflineStream
import com.k2fsa.sherpa.onnx.QnnConfig
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 内置模型：在本进程里跑 SenseVoice（sherpa-onnx），完全不经过引擎。
 *
 * 为什么要有它：引擎侧的语音模型只在「本机引擎」可用 —— 远程主机的隧道白名单里没有
 * speech 路由（见 #1067），系统识别又会被国产 ROM 的识别服务挡住（#471）。把模型搬进
 * App 进程后，引擎在不在、连的是本机还是远程、网络通不通，都不影响听写。
 *
 * 用法：`transcribe(pcm16le)` 是同步的，调用方自己放到后台线程。
 */
internal object SenseVoiceEngine {
    private const val TAG = "DshVoice"

    /** assets 下的模型文件名（sherpa 用 AssetManager 时必须是相对路径）。 */
    private const val MODEL_ASSET = "voice/model.int8.onnx"
    private const val TOKENS_ASSET = "voice/tokens.txt"

    /**
     * 大模型要先从 assets 解到私有目录再交给 sherpa：AssetManager 打开 228 MB 的
     * onnx 会失败（它按压缩流处理），而解出来的文件 sherpa 能直接 mmap。
     */
    private const val MODEL_DIR = "voice-model"
    private const val MODEL_FILE = "model.int8.onnx"
    private const val TOKENS_FILE = "tokens.txt"

    private val preparing = AtomicBoolean(false)

    @Volatile private var recognizer: OfflineRecognizer? = null
    @Volatile private var loadFailure: String? = null

    /** 模型是否已就绪（不触发加载）。 */
    fun isReady(): Boolean = recognizer != null

    /** 最近一次加载失败的原因，供界面提示。 */
    fun failure(): String? = loadFailure

    /**
     * 准备好识别器；重复调用只做一次。返回 null 表示可用，否则是失败原因。
     *
     * 首次调用要把 228 MB 模型从 assets 拷到私有目录，约 10–30 秒；之后的启动直接 mmap。
     */
    @Synchronized
    fun prepare(context: Context): String? {
        recognizer?.let { return null }
        loadFailure?.let { return it }
        if (preparing.get()) return "正在准备模型"
        preparing.set(true)
        return try {
            val model = extract(context, MODEL_ASSET, MODEL_FILE)
            val tokens = extract(context, TOKENS_ASSET, TOKENS_FILE)
            Log.i(TAG, "sensevoice: model=${model.length()} tokens=${tokens.length()}")

            val senseVoice = OfflineSenseVoiceModelConfig(
                model.absolutePath,
                "zh",
                false,
                // sherpa 的 Kotlin 构造把这些参数声明为非空；空串表示不用 QNN 后端。
                QnnConfig("", "", ""),
            )
            val modelConfig = OfflineModelConfig().apply {
                this.senseVoice = senseVoice
                this.tokens = tokens.absolutePath
                this.numThreads = 2
                this.modelType = "sense-voice"
            }
            val config = OfflineRecognizerConfig().apply {
                this.modelConfig = modelConfig
                this.decodingMethod = "greedy_search"
            }
            // Absolute paths above mean the asset manager must not be consulted.
            val created = OfflineRecognizer(null as AssetManager?, config)
            recognizer = created
            loadFailure = null
            null
        } catch (error: Throwable) {
            val reason = error.message ?: error.javaClass.simpleName
            loadFailure = reason
            Log.w(TAG, "sensevoice: prepare failed: $reason", error)
            reason
        } finally {
            preparing.set(false)
        }
    }

    /**
     * 转写一段 16 kHz 单声道 PCM16。
     *
     * @return 识别出的文字；空串表示这段音频里没有识别到内容。
     */
    fun transcribe(pcm: ByteArray): String {
        val engine = recognizer ?: throw IllegalStateException(loadFailure ?: "模型尚未就绪")
        if (pcm.size < 2) return ""
        val samples = FloatArray(pcm.size / 2)
        var index = 0
        while (index + 1 < pcm.size) {
            val low = pcm[index].toInt() and 0xFF
            val high = pcm[index + 1].toInt()
            val value = (high shl 8) or low
            samples[index / 2] = value / 32768.0f
            index += 2
        }
        val stream: OfflineStream = engine.createStream()
        return try {
            // acceptWaveform's second argument is the sample rate, not the sample
            // count. Passing samples.size made sherpa treat one second as one
            // sample (the log showed in_sample_rate equal to the sample count),
            // so every recording was resampled into noise.
            stream.acceptWaveform(samples, WavRecorder.TARGET_RATE)
            engine.decode(stream)
            engine.getResult(stream).text.orEmpty().trim()
        } finally {
            stream.release()
        }
    }

    /** 释放识别器（模型文件留在磁盘上，下次直接复用）。 */
    @Synchronized
    fun release() {
        recognizer?.release()
        recognizer = null
    }

    /** Copies an asset into the app's private dir, replacing a stale copy of a different size. */
    private fun extract(context: Context, asset: String, name: String): File {
        val dir = File(context.filesDir, MODEL_DIR).apply { mkdirs() }
        val target = File(dir, name)
        val assets = context.assets
        // Do not use openFd here: it throws on a compressed asset ("can not be opened as a file
        // descriptor"), and the packaging of a given build is not something this code controls.
        // The manifest in model.lock.json pins the expected size instead.
        val expected = assetSize(assets, asset)
        if (target.exists() && (expected == 0L || target.length() == expected)) return target
        // Write beside it and rename, so a kill mid-copy never leaves a truncated model.
        val staging = File(dir, "$name.tmp")
        assets.open(asset).use { input ->
            FileOutputStream(staging).use { output ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    output.write(buffer, 0, read)
                }
            }
        }
        if (target.exists()) target.delete()
        check(staging.renameTo(target)) { "无法落盘语音模型" }
        return target
    }

    /** Size from model.lock.json (or 0 when it cannot be read), used to spot a stale copy. */
    private fun assetSize(assets: AssetManager, asset: String): Long = runCatching {
        val lock = assets.open("voice/model.lock.json").use { it.readBytes().toString(Charsets.UTF_8) }
        val name = asset.substringAfterLast('/')
        val match = Regex("\"name\"\\s*:\\s*\"" + Regex.escape(name) + "\"[^}]*\"bytes\"\\s*:\\s*(\\d+)")
            .find(lock)
        match?.groupValues?.get(1)?.toLong() ?: 0L
    }.getOrDefault(0L)
}
