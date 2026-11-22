package io.github.ccch1mneyyy.dsh_app.companion

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.LongBuffer
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.json.JSONObject
import kotlin.math.sqrt

/** One CPU encoder on the phone. This channel never performs network calls. */
class CompanionEmbeddingPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private var current: EncoderWorker? = null

    private class EncoderWorker(val directory: File) {
        val executor: ExecutorService = Executors.newSingleThreadExecutor()
        // Accessed only on this engine's worker, also when it is detached.
        var model: CompanionEmbeddingModel? = null
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        current = EncoderWorker(File(binding.applicationContext.filesDir, "companion-embedding/bge-small-zh-v1.5-18e2da9"))
        channel = MethodChannel(binding.binaryMessenger, "dsh/companion_embeddings").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("directory", "load", "validate", "embed", "unload")) {
            result.notImplemented()
            return
        }
        val scope = current
        if (scope == null) {
            result.error("embedding_detached", "The local encoder is unavailable", null)
            return
        }
        scope.executor.execute {
            try {
                val value: Any? = when (call.method) {
                    "directory" -> scope.directory.absolutePath
                    "load" -> {
                        // Recover the old complete model after a process death
                        // between the two directory renames during install.
                        val previous = File(scope.directory.path + ".previous")
                        if (!scope.directory.exists() && previous.isDirectory) {
                            require(previous.renameTo(scope.directory))
                        }
                        if (scope.model == null && CompanionEmbeddingModel.filesPresent(scope.directory)) {
                            scope.model = CompanionEmbeddingModel(scope.directory)
                        }
                        scope.model?.let { mapOf("modelKey" to it.key, "dimensions" to 512) }
                    }
                    "validate" -> {
                        val requested = call.argument<String>("directory") ?: error("Missing staging directory")
                        val staging = File(scope.directory.path + ".download")
                        require(File(requested).canonicalFile == staging.canonicalFile)
                        CompanionEmbeddingModel(staging).use { mapOf("modelKey" to it.key, "dimensions" to 512) }
                    }
                    "embed" -> {
                        val active = scope.model ?: error("Local model has not been loaded")
                        require(call.argument<String>("modelKey") == active.key)
                        val texts = call.argument<List<String>>("texts") ?: error("Missing text batch")
                        require(texts.isNotEmpty() && texts.size <= 4)
                        val query = call.argument<Boolean>("query") == true
                        texts.map { active.encode(it, query) }
                    }
                    "unload" -> {
                        val previous = scope.model
                        scope.model = null
                        previous?.close()
                        null
                    }
                    else -> null
                }
                main.post { if (current === scope) result.success(value) }
            } catch (failure: CompanionEmbeddingAssetException) {
                main.post {
                    if (current === scope) result.error(
                        "embedding_asset_corrupt", "A local model asset could not be verified", mapOf("asset" to failure.asset),
                    )
                }
            } catch (_: LinkageError) {
                // ORT/JNI capability failures must settle this channel call.
                // This does not claim to recover from a native process crash.
                main.post {
                    if (current === scope) result.error("embedding_unavailable", "The local encoder could not run", null)
                }
            } catch (_: Exception) {
                // Do not expose user text, model paths or exception bodies in
                // platform error details, logs, or a remote diagnostic event.
                main.post {
                    if (current === scope) result.error("embedding_unavailable", "The local encoder could not run", null)
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        val scope = current
        current = null
        scope?.executor?.execute {
            val previous = scope.model
            scope.model = null
            previous?.close()
        }
        scope?.executor?.shutdown()
    }
}

private class CompanionEmbeddingAssetException(val asset: String) : Exception()

private class CompanionEmbeddingModel(directory: File) : AutoCloseable {
    val key: String
    private val tokenizer: CompanionWordPiece
    private val environment = OrtEnvironment.getEnvironment()
    private val options = OrtSession.SessionOptions()
    private val session: OrtSession

    init {
        var opened: OrtSession? = null
        try {
            for ((name, size, sha) in weights) {
                val file = File(directory, name)
                if (!file.isFile || file.length() != size || digest(file) != sha) {
                    throw CompanionEmbeddingAssetException(name)
                }
            }
            val tokenFile = File(directory, "tokenizer.json")
            require(tokenFile.isFile && tokenFile.length() in 1L..524288L)
            val tokenBytes = tokenFile.readBytes()
            tokenizer = CompanionWordPiece(tokenBytes.toString(Charsets.UTF_8))
            // tokenizer.json is an ordinary Git file at the immutable model
            // revision. Its actual byte hash also belongs to every cache key.
            val tokenizerHash = hex(MessageDigest.getInstance("SHA-256").digest(tokenBytes))
            val source = JSONObject(File(directory, "SOURCE.json").readText(Charsets.UTF_8))
            require(source.getString("revision") == "18e2da99700c49ed48c0a0e3683da39348fbbb36")
            require(source.getString("tokenizer_sha256") == tokenizerHash)
            key = "bge-small-zh-v1.5:18e2da99700c49ed48c0a0e3683da39348fbbb36:int8:cls-l2:wp1:$tokenizerHash"
            options.setIntraOpNumThreads(1)
            options.setInterOpNumThreads(1)
            // Loading a filename preserves the ONNX external-data sibling
            // relationship. Reuse the app's existing ORT; no new EP or engine.
            val loaded = environment.createSession(File(directory, "model_quantized.onnx").path, options)
            opened = loaded
            require(loaded.inputNames == setOf("input_ids", "attention_mask", "token_type_ids") ||
                loaded.inputNames == setOf("input_ids", "attention_mask"))
            require(loaded.outputNames.contains("last_hidden_state"))
            session = loaded
        } catch (failure: Exception) {
            try { opened?.close() } finally { options.close() }
            throw failure
        } catch (failure: LinkageError) {
            try { opened?.close() } finally { options.close() }
            throw failure
        }
    }

    fun encode(text: String, query: Boolean): List<Double> {
        val input = tokenizer.encode((if (query) "为这个句子生成表示以用于检索相关文章：" else "") + text)
        val shape = longArrayOf(1, input.size.toLong())
        val tensors = linkedMapOf<String, OnnxTensor>()
        try {
            tensors["input_ids"] = OnnxTensor.createTensor(environment, LongBuffer.wrap(input), shape)
            tensors["attention_mask"] = OnnxTensor.createTensor(environment, LongBuffer.wrap(LongArray(input.size) { 1 }), shape)
            if (session.inputNames.contains("token_type_ids")) {
                tensors["token_type_ids"] = OnnxTensor.createTensor(environment, LongBuffer.wrap(LongArray(input.size)), shape)
            }
            return session.run(tensors).use { result ->
                val hidden = result.get("last_hidden_state").orElseThrow { IllegalStateException("Missing model output") } as OnnxTensor
                val outputShape = (hidden.info as TensorInfo).shape
                require(outputShape.contentEquals(longArrayOf(1, input.size.toLong(), 512)))
                val batch = hidden.value as Array<*>
                val sequence = batch[0] as Array<*>
                val cls = sequence[0] as FloatArray
                require(cls.size == 512)
                var squared = 0.0
                for (value in cls) {
                    require(value.isFinite())
                    squared += value.toDouble() * value.toDouble()
                }
                require(squared.isFinite() && squared > 0)
                val norm = sqrt(squared)
                cls.map { it.toDouble() / norm }
            }
        } finally {
            tensors.values.forEach { it.close() }
        }
    }

    override fun close() {
        try { session.close() } finally { options.close() }
    }

    companion object {
        // Publisher's LFS SHA256/size at the immutable commit above; tokenizer
        // is revision-pinned metadata, not claimed to have a published SHA256.
        private val weights = listOf(
            Triple("model_quantized.onnx", 168002L, "99a6e522710c00220c89f8c52e0cc5aa09d4cbb1c34c0e932eab3a9dfdc65df3"),
            Triple("model_quantized.onnx_data", 23774208L, "952623481ca8beea884e3d3c9ecaf8a3c7bf1d0c21de29e970cd31af9d37a90b"),
        )

        fun filesPresent(directory: File): Boolean = weights.all { (name, size, _) ->
            File(directory, name).let { it.isFile && it.length() == size }
        } && File(directory, "tokenizer.json").isFile && File(directory, "SOURCE.json").isFile

        private fun digest(file: File): String {
            val hash = MessageDigest.getInstance("SHA-256")
            file.inputStream().buffered().use { input ->
                val buffer = ByteArray(65536)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    hash.update(buffer, 0, count)
                }
            }
            return hex(hash.digest())
        }

        private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}
