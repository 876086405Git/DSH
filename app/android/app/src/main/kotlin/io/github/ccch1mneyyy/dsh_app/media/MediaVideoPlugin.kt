package io.github.ccch1mneyyy.dsh_app.media

import android.app.Activity
import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Local materialized videos only; intentionally separate from launch playback. */
class MediaVideoPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var textures: TextureRegistry
    private lateinit var app: Application
    private lateinit var audio: AudioManager
    private val main = Handler(Looper.getMainLooper())
    private val clips = HashMap<Long, Clip>()
    private val posterWorker = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-video-poster").apply { isDaemon = true } }
    private val probing = AtomicBoolean(false)
    private var activity: Activity? = null
    private var foreground = false
    private var attached = false
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private class Clip(val producer: TextureRegistry.SurfaceProducer, val player: MediaPlayer) {
        var prepared = false
        var rotation: Int? = null
        var pending: MethodChannel.Result? = null
        var timeout: Runnable? = null
    }
    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(a: Activity) { if (a === activity) foreground = true }
        override fun onActivityPaused(a: Activity) { if (a === activity) { foreground = false; pauseAll() } }
        override fun onActivityCreated(a: Activity, state: Bundle?) {}
        override fun onActivityStarted(a: Activity) {}
        override fun onActivityStopped(a: Activity) {}
        override fun onActivitySaveInstanceState(a: Activity, state: Bundle) {}
        override fun onActivityDestroyed(a: Activity) { if (a === activity) closeAll() }
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext as Application
        audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        textures = binding.textureRegistry
        methods = MethodChannel(binding.binaryMessenger, "dsh/media_video").also { it.setMethodCallHandler(this) }
        attached = true
        app.registerActivityLifecycleCallbacks(lifecycle)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        methods.setMethodCallHandler(null)
        app.unregisterActivityLifecycleCallbacks(lifecycle)
        closeAll()
        posterWorker.shutdownNow()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() { foreground = false; closeAll(); activity = null }
    override fun onDetachedFromActivity() = onDetachedFromActivityForConfigChanges()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "open") { open(call.argument<String>("path"), result); return }
        if (call.method == "poster") { poster(call.argument<String>("path"), result); return }
        val id = call.argument<Number>("texture")?.toLong() ?: -1L
        if (call.method == "close") { close(id); result.success(null); return }
        val clip = clips[id]
        if (clip == null || !clip.prepared) { result.error("closed", "video is closed", null); return }
        try {
            when (call.method) {
                "play" -> {
                    if (!foreground) { result.error("background", "app is not in foreground", null); return }
                    if (!requestFocus()) { result.error("audio_focus", "audio focus unavailable", null); return }
                    clips.values.filter { it !== clip && it.prepared }.forEach { runCatching { it.player.pause() } }
                    clip.player.start()
                    result.success(null)
                }
                "pause" -> { clip.player.pause(); abandonFocus(); result.success(null) }
                "seek" -> {
                    val position = MediaVideos.seek(call.argument<Number>("positionMs")?.toLong() ?: 0, clip.player.duration)
                    if (Build.VERSION.SDK_INT >= 26) clip.player.seekTo(position.toLong(), MediaPlayer.SEEK_CLOSEST_SYNC) else clip.player.seekTo(position)
                    result.success(null)
                }
                "state" -> result.success(mapOf("positionMs" to clip.player.currentPosition, "durationMs" to clip.player.duration, "playing" to clip.player.isPlaying))
                else -> result.notImplemented()
            }
        } catch (_: Exception) { close(id); result.error("playback", "video playback failed", null) }
    }

    private fun open(path: String?, result: MethodChannel.Result) {
        if (!MediaVideos.localFile(path)) { result.error("invalid", "a local video file is required", null); return }
        closeAll()
        var producer: TextureRegistry.SurfaceProducer? = null
        var player: MediaPlayer? = null
        try {
            producer = textures.createSurfaceProducer()
            player = MediaPlayer()
            val p = player
            val surface = producer
            val id = surface.id()
            val clip = Clip(surface, p).also { it.pending = result }
            if (surface.handlesCropAndRotation()) clip.rotation = 0
            // Answers once the player is prepared and the rotation is known, in either order.
            fun publish() {
                val rotation = clip.rotation ?: return
                if (!clip.prepared) return
                clip.timeout?.let(main::removeCallbacks)
                val pending = clip.pending
                clip.pending = null
                pending?.success(mapOf("texture" to id, "width" to p.videoWidth, "height" to p.videoHeight, "durationMs" to p.duration, "rotation" to rotation))
            }
            clips[id] = clip
            val timeout = Runnable {
                // A prepared player still opens; an unread rotation just falls back to none.
                if (clip.pending == null) return@Runnable
                if (clip.prepared) { clip.rotation = clip.rotation ?: 0; publish() } else close(id, "timeout")
            }
            clip.timeout = timeout
            main.postDelayed(timeout, 20_000)
            surface.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() { if (clips[id] === clip) runCatching { p.setSurface(surface.surface) } }
                override fun onSurfaceCleanup() {
                    if (clips[id] === clip) { pauseAll(); runCatching { p.setSurface(null) } }
                }
            })
            p.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            p.setOnVideoSizeChangedListener { _, w, h -> if (clips[id] === clip && w > 0 && h > 0) surface.setSize(w, h) }
            p.setOnCompletionListener { if (clips[id] === clip) abandonFocus() }
            p.setOnErrorListener { _, _, _ -> close(id, "playback"); true }
            p.setOnPreparedListener {
                if (clips[id] !== clip) return@setOnPreparedListener
                if (it.videoWidth <= 0 || it.videoHeight <= 0) { close(id, "unsupported"); return@setOnPreparedListener }
                clip.prepared = true
                surface.setSize(it.videoWidth, it.videoHeight)
                publish()
            }
            FileInputStream(path!!).use { p.setDataSource(it.fd) }
            // A container without an index can take a full scan: read it off the platform thread, on its
            // own thread so a stale scan never delays the next video.
            if (clip.rotation == null) Thread({
                val rotation = videoRotation(path)
                main.post { if (clips[id] === clip) { clip.rotation = rotation; publish() } }
            }, "dsh-video-rotation").apply { isDaemon = true }.start()
            p.setSurface(surface.surface)
            p.prepareAsync()
        } catch (_: Exception) {
            val id = producer?.id()
            if (id != null && clips.containsKey(id)) close(id, "unsupported") else {
                runCatching { player?.release() }
                runCatching { producer?.release() }
                result.error("unsupported", "cannot open video", null)
            }
        }
    }

    /** Display dimensions already include rotation; only the untransformed texture needs it. */
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

    private fun requestFocus(): Boolean {
        if (focusListener != null) return true
        val listener = object : AudioManager.OnAudioFocusChangeListener {
            override fun onAudioFocusChange(change: Int) {
                if (change <= 0) main.post {
                    // A queued loss must not pause a later request; cleanup here is best effort.
                    if (focusListener === this) runCatching { pauseAll() }
                }
            }
        }
        focusListener = listener
        var granted = false
        try {
            granted = audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            return granted
        } finally {
            if (!granted) abandonFocus()
        }
    }
    private fun abandonFocus() {
        val listener = focusListener ?: return
        focusListener = null
        audio.abandonAudioFocus(listener)
    }
    private fun pauseAll() {
        clips.values.filter { it.prepared }.forEach { runCatching { it.player.pause() } }
        abandonFocus()
    }
    private fun closeAll() { clips.keys.toList().forEach { close(it) }; abandonFocus() }
    private fun close(id: Long, code: String = "closed") {
        val clip = clips.remove(id) ?: return
        clip.timeout?.let(main::removeCallbacks)
        clip.pending?.error(code, "video unavailable", null)
        clip.pending = null
        runCatching { clip.player.release() }
        runCatching { clip.producer.release() }
        if (clips.isEmpty()) abandonFocus()
    }

    private fun poster(path: String?, result: MethodChannel.Result) {
        if (!MediaVideos.localFile(path)) { result.error("invalid", "a local video file is required", null); return }
        // A broken platform decoder must not accumulate workers when cards scroll.
        if (!probing.compareAndSet(false, true)) { result.success(null); return }
        var answered = false
        val timeout = Runnable { if (!answered) { answered = true; result.error("timeout", "poster extraction timed out", null) } }
        main.postDelayed(timeout, 10_000)
        posterWorker.execute {
            val bytes = runCatching {
                val retriever = MediaMetadataRetriever()
                try {
                    FileInputStream(path!!).use { retriever.setDataSource(it.fd) }
                    val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                    val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                    if (w <= 0 || h <= 0) return@runCatching null
                    // API 26 cannot request a scaled frame: avoid a large full-resolution
                    // bitmap just for a scrolling card. Playback is still available.
                    if (Build.VERSION.SDK_INT < 27 && w.toLong() * h > 4_000_000L) return@runCatching null
                    val (pw, ph) = MediaVideos.posterSize(w, h)
                    val frame = if (Build.VERSION.SDK_INT >= 27) retriever.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, pw, ph) else retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    if (frame == null) return@runCatching null
                    try {
                        val (sw, sh) = MediaVideos.posterSize(frame.width, frame.height)
                        val scaled = if (sw == frame.width && sh == frame.height) frame else Bitmap.createScaledBitmap(frame, sw, sh, true)
                        try { ByteArrayOutputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, 80, it); it.toByteArray() } }
                        finally { if (scaled !== frame) scaled.recycle() }
                    } finally { frame.recycle() }
                } finally { runCatching { retriever.release() } }
            }.getOrNull()
            probing.set(false)
            main.post {
                main.removeCallbacks(timeout)
                if (!answered) { answered = true; if (attached) result.success(bytes) }
            }
        }
    }
}

internal object MediaVideos {
    fun localFile(path: String?): Boolean = path != null && File(path).isAbsolute && File(path).isFile
    fun seek(position: Long, duration: Int): Int = position.coerceIn(0L, maxOf(0, duration).toLong()).toInt()
    fun posterSize(width: Int, height: Int): Pair<Int, Int> {
        val scale = minOf(1.0, 512.0 / maxOf(1, width, height))
        return maxOf(1, (width * scale).toInt()) to maxOf(1, (height * scale).toInt())
    }
}
