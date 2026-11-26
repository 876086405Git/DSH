package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context

/** Optional resources owned by a live local turn, never by the persisted preferences alone. Main thread only. */
internal class AndroidBackgroundProtection private constructor(private val app: Context) {
    private val prefs = app.getSharedPreferences("dsh_background_protection", Context.MODE_PRIVATE)
    private var appVisible = false
    private var turnRunning = false
    private var service: DshService? = null
    private val audio = SilentBackgroundAudio()
    private val location = ApproximateBackgroundLocation(app, { service?.setLocationForeground(it) == true }, ::refresh)
    private var audioFailed = false
    private var locationFailed = false

    private val audioEnabled get() = prefs.getBoolean("audio", false)
    private val locationEnabled get() = prefs.getBoolean("location", false)
    val locationEnabledInSystem get() = location.enabledInSystem
    fun hasCoarseLocation(): Boolean = location.hasCoarseLocation()
    fun hasBackgroundLocation(): Boolean = location.hasBackgroundLocation()

    fun status(): Map<String, Any?> = mapOf(
        "supported" to true,
        "audioEnabled" to audioEnabled,
        "locationEnabled" to locationEnabled,
        "audioActive" to audio.isPlaying,
        "locationActive" to (location.isRegistered && locationEnabledInSystem && hasBackgroundLocation()),
        "locationAuthorization" to when {
            hasBackgroundLocation() -> "authorizedAlways"
            hasCoarseLocation() -> "authorizedWhenInUse"
            else -> "notDetermined"
        },
        "error" to when {
            locationEnabled && !locationEnabledInSystem -> LOCATION_DISABLED
            locationEnabled && locationFailed -> "android_background_location_unavailable"
            audioEnabled && audioFailed -> "android_background_audio_unavailable"
            else -> null
        },
    )

    fun setEnabled(audioEnabled: Boolean?, locationEnabled: Boolean?) {
        prefs.edit().also { edit ->
            audioEnabled?.let { edit.putBoolean("audio", it); audioFailed = false }
            locationEnabled?.let { edit.putBoolean("location", it); locationFailed = false }
        }.apply()
        refresh()
    }

    fun setAppVisible(visible: Boolean) {
        appVisible = visible
        refresh()
    }

    fun setTurnRunning(running: Boolean) {
        turnRunning = running
        refresh()
    }

    fun attach(owner: DshService) {
        service = owner
        refresh()
    }

    fun detach(owner: DshService) {
        if (service !== owner) return
        audio.stop()
        location.stop()
        service = null
        turnRunning = false
    }

    fun refresh() {
        if (service == null) return
        val active = turnRunning && !appVisible && RuntimeController.get(app).phase == RuntimeController.Phase.RUNNING
        if (active && audioEnabled) audioFailed = !audio.start() else audio.stop()
        if (active && locationEnabled && locationEnabledInSystem && hasBackgroundLocation()) {
            if (!location.isRegistered) locationFailed = !location.start()
        } else location.stop()
    }

    companion object {
        const val LOCATION_DISABLED = "android_background_location_services_disabled"
        private var instance: AndroidBackgroundProtection? = null
        fun get(context: Context): AndroidBackgroundProtection = instance
            ?: AndroidBackgroundProtection(context.applicationContext).also { instance = it }
    }
}
