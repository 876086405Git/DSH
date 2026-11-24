package io.github.ccch1mneyyy.dsh_app.companion

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.nativemedia.ClipPlayer
import java.io.File
import java.util.Locale

/**
 * Her voice in 伙伴小屋: the phone's own text-to-speech, MethodChannel `dsh/companion_voice`
 * (lib/companion/companion_voice.dart). The app keeps no audio; the system's engine does what it
 * does with the text.
 *
 * `ready` initializes the engine (retrying a failed init on a later call) and answers whether it
 * can speak the language asked for.
 * `speak` queues one sentence under an id (or replaces everything with `flush`); `play` plays one
 * sentence of an external voice from a file the app fetched (lib/companion/companion_voice_source.dart);
 * `stop` drops what is speaking, playing and queued. Progress comes back on the same channel as `event` calls: `start`,
 * `range` (Android 8+: the characters being spoken now, for her mouth), `done`, `stopped`, `error`.
 *
 * Audio focus for the phone's voice: transient, others duck, held while lines are queued or speaking
 * and a moment after (she often talks while operating another app). Losing it ends what she is
 * saying. A refused request still speaks, as before: focus is for the others, not a gate on her voice.
 */
class CompanionVoicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null

    /** The engine's init result; null while it starts. */
    private var status: Int? = null
    private val waiting = mutableListOf<Pair<String, MethodChannel.Result>>()

    private val audio by lazy { context.getSystemService(AudioManager::class.java) }
    private var focus: AudioFocusRequest? = null

    /** Lines handed to the engine and not yet ended: focus is held while there are some. */
    private val speaking = HashSet<String>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        tts?.stop()
        speaking.clear()
        abandonFocus()
        tts?.shutdown()
        tts = null
        playing = null
        player?.release()
        player = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> ready(call.argument<String>("language") ?: "zh-CN", result)
            "speak" -> result.success(speak(call))
            "play" -> result.success(play(call))
            "stop" -> {
                tts?.stop()
                speaking.clear()
                abandonFocus()
                playing = null
                player?.release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun ready(language: String, result: MethodChannel.Result) {
        if (status == TextToSpeech.ERROR) {
            tts?.shutdown()
            tts = null
            status = null
        }
        val engine = tts
        if (engine != null && status != null) {
            result.success(use(engine, language))
            return
        }
        waiting.add(language to result)
        if (engine != null) return
        tts = TextToSpeech(context) { code ->
            main.post {
                status = code
                val started = tts
                started?.setOnUtteranceProgressListener(progress)
                started?.setAudioAttributes(SPEECH)
                val answers = waiting.toList()
                waiting.clear()
                for ((lang, answer) in answers) answer.success(started != null && use(started, lang))
            }
        }
    }

    private fun use(engine: TextToSpeech, language: String): Boolean {
        if (status != TextToSpeech.SUCCESS) return false
        return runCatching {
            val locale = Locale.forLanguageTag(language)
            val ok = engine.isLanguageAvailable(locale) >= TextToSpeech.LANG_AVAILABLE
            ok && engine.setLanguage(locale) >= TextToSpeech.LANG_AVAILABLE
        }.getOrDefault(false)
    }

    private fun speak(call: MethodCall): Boolean {
        val engine = tts ?: return false
        if (status != TextToSpeech.SUCCESS) return false
        val id = call.argument<String>("id") ?: return false
        val text = call.argument<String>("text") ?: return false
        engine.setSpeechRate((call.argument<Double>("rate") ?: 1.0).toFloat())
        engine.setPitch((call.argument<Double>("pitch") ?: 1.0).toFloat())
        val queue = if (call.argument<Boolean>("flush") == true) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD
        if (queue == TextToSpeech.QUEUE_FLUSH) speaking.clear()
        // Others duck before her first word.
        requestFocus()
        if (engine.speak(text, queue, Bundle(), id) != TextToSpeech.SUCCESS) {
            if (speaking.isEmpty()) abandonFocus()
            return false
        }
        speaking += id
        return true
    }

    private fun ended(type: String, id: String?) {
        send(type, id)
        main.post {
            if (speaking.remove(id) && speaking.isEmpty()) {
                // Her next line often follows within a moment: others don't bob back up in between.
                main.removeCallbacks(release)
                main.postDelayed(release, 1_000)
            }
        }
    }

    private val release = Runnable { if (speaking.isEmpty()) abandonFocus() }

    private fun requestFocus() {
        if (focus != null) return
        val am = audio ?: return
        lateinit var request: AudioFocusRequest
        request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(SPEECH)
            .setOnAudioFocusChangeListener { change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                    // A late event for an already-abandoned request leaves a newer line alone.
                    main.post {
                        if (focus === request) {
                            tts?.stop()
                            speaking.clear()
                            abandonFocus()
                        }
                    }
                }
            }
            .build()
        // Refused: she speaks anyway, and her next line asks again. The refused request is still
        // registered with the system, so it is abandoned now rather than left to pile up.
        if (am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) focus = request
        else runCatching { am.abandonAudioFocusRequest(request) }
    }

    private fun abandonFocus() {
        main.removeCallbacks(release)
        val request = focus ?: return
        focus = null
        runCatching { audio?.abandonAudioFocusRequest(request) }
    }

    // An external voice's sentence, as an audio file the app fetched: one at a time, through the
    // same player as plugin clips (audio focus, interruptions, late callbacks all handled there).
    private var player: ClipPlayer? = null
    private var playing: String? = null

    private fun play(call: MethodCall): Boolean {
        val id = call.argument<String>("id") ?: return false
        val path = call.argument<String>("path") ?: return false
        val file = File(path)
        if (!file.isFile) return false
        val clips = player ?: ClipPlayer(
            context,
            object : ClipPlayer.Listener {
                override fun onStarted() = send("start", playing)

                override fun onEnded() = send("done", playing.also { playing = null })

                override fun onStopped(reason: String) = send("stopped", playing.also { playing = null })

                override fun onError(reason: String) = send("error", playing.also { playing = null })
            },
        ).also { player = it }
        // The one before ends here; nothing more comes from it.
        playing?.let { send("stopped", it) }
        playing = id
        return clips.play(file).also { if (!it) playing = null }
    }

    private fun send(type: String, id: String?, start: Int? = null, end: Int? = null) {
        main.post {
            methods.invokeMethod("event", mapOf("type" to type, "id" to id, "start" to start, "end" to end))
        }
    }

    private val progress =
        object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) = send("start", utteranceId)

            override fun onDone(utteranceId: String?) = ended("done", utteranceId)

            override fun onStop(utteranceId: String?, interrupted: Boolean) = ended("stopped", utteranceId)

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) = ended("error", utteranceId)

            override fun onError(utteranceId: String?, errorCode: Int) = ended("error", utteranceId)

            override fun onRangeStart(utteranceId: String?, start: Int, end: Int, frame: Int) =
                send("range", utteranceId, start, end)
        }

    companion object {
        private const val CHANNEL = "dsh/companion_voice"

        /** The same as an external voice's sentences (ClipPlayer): speech on the media volume. */
        private val SPEECH: AudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
    }
}
