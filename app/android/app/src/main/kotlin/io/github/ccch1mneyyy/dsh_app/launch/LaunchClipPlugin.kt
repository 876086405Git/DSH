package io.github.ccch1mneyyy.dsh_app.launch

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream
import kotlin.concurrent.thread

/**
 * A custom launch screen's clip (app/lib/launch/launch_video.dart): MethodChannel `dsh/launch_clip`.
 * The platform's MediaPlayer onto a Flutter texture, silent, played once; the last frame stays.
 *
 * - `probe {path, poster}` → `{durationMs, width, height}` (rotation applied) and the first frame
 *   written as a PNG at `poster`; null when it isn't a playable video.
 * - `open {path}` → `{texture, rotation}` once prepared and the texture rotation is known.
 * - `play {texture}`; native → Dart `showing {texture}` at the first frame drawn, `done {texture}`
 *   at the end.
 * - `close {texture}`.
 */
class LaunchClipPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var textures: TextureRegistry
    private val main = Handler(Looper.getMainLooper())
    private val clips = HashMap<Long, Clip>()

    private class Clip(val producer: TextureRegistry.SurfaceProducer, val player: MediaPlayer) {
        var prepared = false
        var wantPlay = false
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textures = binding.textureRegistry
        methods = MethodChannel(binding.binaryMessenger, "dsh/launch_clip").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        for (id in clips.keys.toList()) close(id)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> {
                val path = call.argument<String>("path")
                val poster = call.argument<String>("poster")
                if (path == null || poster == null) {
                    result.error("invalid", null, null)
                    return
                }
                thread(name = "dsh-launch-probe", isDaemon = true) {
                    val answer = probe(path, poster)
                    main.post { result.success(answer) }
                }
            }
            "open" -> open(call.argument<String>("path"), result)
            "play" -> {
                val clip = clips[call.argument<Number>("texture")?.toLong() ?: -1L]
                if (clip != null) {
                    clip.wantPlay = true
                    if (clip.prepared) startOrDone(clip)
                }
                result.success(clip != null)
            }
            "close" -> {
                call.argument<Number>("texture")?.toLong()?.let { close(it) }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun open(path: String?, result: MethodChannel.Result) {
        if (path == null || !File(path).isFile) {
            result.success(null)
            return
        }
        val producer = textures.createSurfaceProducer()
        val player = MediaPlayer()
        val clip = Clip(producer, player)
        val id = producer.id()
        clips[id] = clip
        var rotation: Int? = if (producer.handlesCropAndRotation()) 0 else null
        var answered = false
        fun answer(value: Any?) {
            if (answered) return
            answered = true
            result.success(value)
        }
        fun publish() {
            val angle = rotation ?: return
            if (clip.prepared) answer(mapOf("texture" to id, "rotation" to angle))
        }
        try {
            player.setDataSource(path)
            player.setVolume(0f, 0f)
            player.isLooping = false
            producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    runCatching { player.setSurface(producer.surface) }
                }

                override fun onSurfaceCleanup() {
                    runCatching { player.setSurface(null) }
                }
            })
            player.setOnVideoSizeChangedListener { _, w, h -> if (w > 0 && h > 0) producer.setSize(w, h) }
            player.setOnInfoListener { _, what, _ ->
                if (what == MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START) methods.invokeMethod("showing", mapOf("texture" to id))
                false
            }
            player.setOnCompletionListener { methods.invokeMethod("done", mapOf("texture" to id)) }
            player.setOnErrorListener { _, _, _ ->
                if (!answered) close(id)
                methods.invokeMethod("done", mapOf("texture" to id))
                answer(null)
                true
            }
            player.setOnPreparedListener {
                clip.prepared = true
                if (it.videoWidth > 0 && it.videoHeight > 0) producer.setSize(it.videoWidth, it.videoHeight)
                publish()
                if (clip.wantPlay) startOrDone(clip)
            }
            // A slow metadata scan must not block the platform thread or another open.
            if (rotation == null) thread(name = "dsh-launch-rotation", isDaemon = true) {
                val angle = videoRotation(path)
                main.post { if (clips[id] === clip) { rotation = angle; publish() } }
            }
            player.setSurface(producer.surface)
            player.prepareAsync()
        } catch (_: Exception) {
            close(id)
            answer(null)
        }
    }

    private fun videoRotation(path: String): Int = runCatching {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            when (val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0) {
                90, 180, 270 -> rotation
                else -> 0
            }
        } finally {
            runCatching { retriever.release() }
        }
    }.getOrDefault(0)

    private fun startOrDone(clip: Clip) {
        try {
            clip.player.start()
        } catch (_: Exception) {
            methods.invokeMethod("done", mapOf("texture" to clip.producer.id()))
        }
    }

    private fun close(id: Long) {
        val clip = clips.remove(id) ?: return
        runCatching { clip.player.release() }
        runCatching { clip.producer.release() }
    }

    private fun probe(path: String, poster: String): Map<String, Any>? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            if (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) != "yes") return null
            val ms = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: return null
            val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: return null
            val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: return null
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val (width, height) = LaunchClips.shown(w, h, rotation)
            val frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: return null
            val scaled = LaunchClips.posterSize(frame.width, frame.height).let { (pw, ph) ->
                if (pw == frame.width && ph == frame.height) frame else Bitmap.createScaledBitmap(frame, pw, ph, true)
            }
            val encoded = FileOutputStream(poster).use { scaled.compress(Bitmap.CompressFormat.PNG, 100, it) }
            if (scaled !== frame) scaled.recycle()
            frame.recycle()
            if (!encoded) return null
            mapOf("durationMs" to ms.toInt(), "width" to width, "height" to height)
        } catch (_: Exception) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }
}

/** Pure parts of [LaunchClipPlugin], unit-tested on the JVM. */
internal object LaunchClips {
    /** The poster's long side at most: a phone screen's. */
    private const val POSTER_SIDE = 1440

    /** The frame as shown: a quarter turn swaps the stored width and height. */
    fun shown(width: Int, height: Int, rotation: Int): Pair<Int, Int> =
        if (((rotation % 360) + 360) % 360 == 90 || ((rotation % 360) + 360) % 360 == 270) height to width else width to height

    fun posterSize(width: Int, height: Int): Pair<Int, Int> {
        val long = maxOf(width, height)
        if (long <= POSTER_SIDE) return width to height
        val scale = POSTER_SIDE.toDouble() / long
        return maxOf(1, (width * scale).toInt()) to maxOf(1, (height * scale).toInt())
    }
}
