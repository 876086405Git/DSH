package io.github.ccch1mneyyy.dsh_app.companion

import android.app.Activity
import android.app.KeyguardManager
import android.app.assist.AssistStructure
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.speech.RecognitionService
import android.speech.RecognitionListener
import android.speech.SpeechRecognizer
import android.text.InputType
import android.view.View
import android.view.WindowManager
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.phone.PhoneControl
import io.github.ccch1mneyyy.dsh_app.shortcuts.EntryActivity
import java.util.UUID

internal object CompanionAssistant {
    private data class Page(val id: String, val text: String, val capturedAt: Long)
    private var pendingPage: Page? = null

    fun stagePage(text: String?): String? {
        pendingPage = text?.let { Page(UUID.randomUUID().toString(), it, SystemClock.elapsedRealtime()) }
        return pendingPage?.id
    }

    fun takePage(id: String?): String? {
        val page = pendingPage?.takeIf { it.id == id } ?: return null
        pendingPage = null
        return page.text.takeIf { SystemClock.elapsedRealtime() - page.capturedAt < 10_000 }
    }

    private fun preferences(context: Context) =
        context.getSharedPreferences("companion_assistant", Context.MODE_PRIVATE)

    fun sharePage(context: Context): Boolean = preferences(context).getBoolean("share_page", false)

    fun setSharePage(context: Context, enabled: Boolean) {
        preferences(context).edit().putBoolean("share_page", enabled).apply()
    }

    fun selected(context: Context): Boolean = VoiceInteractionService.isActiveService(
        context, ComponentName(context, CompanionAssistantService::class.java),
    )

    fun openSettings(context: Context): Boolean {
        // Older Android versions also set the selected assistant's RecognitionService as
        // the system speech input. Keep the person's current provider for that delegation.
        val service = Settings.Secure.getString(context.contentResolver, "voice_recognition_service")
            ?.let(ComponentName::unflattenFromString)
        if (service != null && service.packageName != context.packageName)
            preferences(context).edit().putString("speech_service", service.flattenToString()).apply()
        for (action in listOf(Settings.ACTION_VOICE_INPUT_SETTINGS, Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)) {
            try {
                context.startActivity(Intent(action))
                return true
            } catch (_: ActivityNotFoundException) {
                // Some OEMs expose only the general default-apps page.
            }
        }
        return false
    }

    fun systemRecognizer(context: Context): ComponentName? {
        val speech = Intent(RecognitionService.SERVICE_INTERFACE)
        val preferred = preferences(context).getString("speech_service", null)?.let(ComponentName::unflattenFromString)
        val services = context.packageManager.queryIntentServices(speech, 0)
        return services.asSequence().map { it.serviceInfo }.map { ComponentName(it.packageName, it.name) }
            .firstOrNull { it == preferred }
            ?: context.packageManager.queryIntentServices(speech, PackageManager.MATCH_SYSTEM_ONLY)
                .asSequence().map { it.serviceInfo }.firstOrNull { it.packageName != context.packageName }
                ?.let { ComponentName(it.packageName, it.name) }
    }
}

class CompanionAssistantService : VoiceInteractionService() {
    override fun onReady() {
        super.onReady()
        setDisabledShowContext(VoiceInteractionSession.SHOW_WITH_SCREENSHOT)
    }

    override fun onLaunchVoiceAssistFromKeyguard() {
        startActivity(CompanionAssistantUnlockActivity.intent(this).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

class CompanionAssistantSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession = CompanionAssistantSession(this)
}

/** A voice-interaction window is unnecessary. The private entry opens the existing Flutter task. */
private class CompanionAssistantSession(context: Context) : VoiceInteractionSession(context) {
    private val main = Handler(Looper.getMainLooper())
    private var awaitingPage = false
    private var returnToApp = false
    private var foregroundActivities: List<ComponentName> = emptyList()
    private val openWithoutPage = Runnable { deliver(null) }

    override fun onCreate() {
        super.onCreate()
        setUiEnabled(false)
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        main.removeCallbacks(openWithoutPage)
        awaitingPage = false
        returnToApp = !MainActivity.inForeground
        if (context.getSystemService(KeyguardManager::class.java).isDeviceLocked) {
            startAssistantActivity(CompanionAssistantUnlockActivity.intent(context))
        } else if (showFlags and SHOW_WITH_ASSIST != 0 && CompanionAssistant.sharePage(context)) {
            foregroundActivities = if (Build.VERSION.SDK_INT >= 35)
                args?.getParcelableArrayList(KEY_FOREGROUND_ACTIVITIES, ComponentName::class.java).orEmpty()
            else emptyList()
            awaitingPage = true
            // System assist data may be withheld or arrive after the user has started speaking.
            main.postDelayed(openWithoutPage, 350)
        } else {
            startAssistantActivity(EntryActivity.companionAssistant(context, returnToApp = returnToApp))
        }
    }

    override fun onHandleAssist(state: AssistState) {
        if (!awaitingPage || !state.isFocused) return
        val structure = state.assistStructure
        if (structure != null && foregroundActivities.isNotEmpty() &&
            structure.activityComponent !in foregroundActivities) return
        deliver(visibleAssistText(structure))
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onHandleAssist(data: Bundle?, structure: AssistStructure?, content: android.app.assist.AssistContent?) {
        if (Build.VERSION.SDK_INT < 29 && awaitingPage) deliver(visibleAssistText(structure))
    }

    private fun deliver(page: String?) {
        if (!awaitingPage) return
        awaitingPage = false
        main.removeCallbacks(openWithoutPage)
        startAssistantActivity(EntryActivity.companionAssistant(context, page, returnToApp))
    }

    override fun onHide() {
        awaitingPage = false
        main.removeCallbacks(openWithoutPage)
        super.onHide()
    }

    override fun onDestroy() {
        main.removeCallbacks(openWithoutPage)
        super.onDestroy()
    }

    private fun visibleAssistText(structure: AssistStructure?): String? {
        structure ?: return null
        val source = structure.activityComponent?.packageName ?: return null
        if (source == context.packageName || PhoneControl.get(context).core.safety.checkRead(source, null) != null) return null
        val queue = ArrayDeque<AssistStructure.ViewNode>()
        for (index in 0 until structure.windowNodeCount) queue.addLast(structure.getWindowNodeAt(index).rootViewNode)
        val lines = linkedSetOf<String>()
        var length = 0
        repeat(300) {
            val node = queue.removeFirstOrNull() ?: return lines.joinToString("\n").takeIf(String::isNotBlank)
            // Skip editable text as well as passwords: a draft may contain a code or private text.
            if (node.visibility != View.VISIBLE || node.isAssistBlocked ||
                node.inputType != InputType.TYPE_NULL || node.className?.endsWith("EditText") == true) return@repeat
            val text = (node.text ?: node.contentDescription)?.toString()?.trim()?.take(400)
            if (!text.isNullOrBlank() && lines.add(text)) length += text.length + 1
            if (length >= 2_000) return lines.joinToString("\n").take(2_000)
            for (index in 0 until node.childCount) queue.addLast(node.getChildAt(index))
        }
        return lines.joinToString("\n").takeIf(String::isNotBlank)
    }
}

/** The person unlocks with Android's own prompt before the room or microphone opens. */
class CompanionAssistantUnlockActivity : Activity() {
    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) setShowWhenLocked(true)
        else window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        window.decorView.post {
            getSystemService(KeyguardManager::class.java)
                .requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() {
                        startActivity(EntryActivity.companionAssistant(this@CompanionAssistantUnlockActivity))
                        finish()
                    }
                    override fun onDismissCancelled() = finish()
                    override fun onDismissError() = finish()
                })
        }
    }

    companion object {
        fun intent(context: Context) = Intent(context, CompanionAssistantUnlockActivity::class.java)
    }
}

/** Older Android may route other apps' system dictation here when switching assistants. */
class CompanionAssistantRecognitionService : RecognitionService() {
    private var recognizer: SpeechRecognizer? = null

    override fun onStartListening(recognizerIntent: Intent, listener: Callback) {
        val provider = CompanionAssistant.systemRecognizer(this)
        if (provider == null) {
            listener.error(SpeechRecognizer.ERROR_CLIENT)
            return
        }
        val speech = SpeechRecognizer.createSpeechRecognizer(this, provider)
        recognizer = speech
        speech.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle) = listener.readyForSpeech(params)
            override fun onBeginningOfSpeech() = listener.beginningOfSpeech()
            override fun onRmsChanged(rmsdB: Float) = listener.rmsChanged(rmsdB)
            override fun onBufferReceived(buffer: ByteArray) = listener.bufferReceived(buffer)
            override fun onEndOfSpeech() = listener.endOfSpeech()
            override fun onPartialResults(partialResults: Bundle) = listener.partialResults(partialResults)
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
            override fun onResults(results: Bundle) {
                if (recognizer !== speech) return
                recognizer = null
                speech.destroy()
                listener.results(results)
            }
            override fun onError(error: Int) {
                if (recognizer !== speech) return
                recognizer = null
                speech.destroy()
                listener.error(error)
            }
        })
        speech.startListening(recognizerIntent)
    }

    override fun onStopListening(listener: Callback) {
        recognizer?.stopListening()
    }

    override fun onCancel(listener: Callback) = release()

    override fun onDestroy() {
        release()
        super.onDestroy()
    }

    private fun release() {
        val speech = recognizer
        recognizer = null
        speech?.destroy()
    }
}
