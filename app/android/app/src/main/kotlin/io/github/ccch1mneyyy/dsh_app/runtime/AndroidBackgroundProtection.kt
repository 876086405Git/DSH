package io.github.ccch1mneyyy.dsh_app.runtime

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.Looper

/** Optional resources owned by a live local turn, never by the persisted preferences alone. Main thread only. */
internal class AndroidBackgroundProtection private constructor(private val app: Context) : LocationListener {
    private val prefs = app.getSharedPreferences("dsh_background_protection", Context.MODE_PRIVATE)
    private val location by lazy { app.getSystemService(Context.LOCATION_SERVICE) as LocationManager }
    private var appVisible = false
    private var turnRunning = false
    private var service: DshService? = null
    private var audio: AudioTrack? = null
    private var provider: String? = null
    private var audioFailed = false
    private var locationFailed = false

    private val audioEnabled get() = prefs.getBoolean("audio", false)
    private val locationEnabled get() = prefs.getBoolean("location", false)
    private val locationEnabledInSystem get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        location.isLocationEnabled
    } else {
        location.getProviders(true).any { it != LocationManager.PASSIVE_PROVIDER }
    }
    fun hasCoarseLocation(): Boolean = granted(Manifest.permission.ACCESS_COARSE_LOCATION)
    private fun hasBackgroundLocation(): Boolean = hasCoarseLocation() &&
        (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION))
    private fun granted(permission: String): Boolean = app.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    fun status(): Map<String, Any?> = mapOf(
        "supported" to true,
        "audioEnabled" to audioEnabled,
        "locationEnabled" to locationEnabled,
        "audioActive" to (audio?.playState == AudioTrack.PLAYSTATE_PLAYING),
        "locationActive" to (provider != null && locationEnabledInSystem && hasBackgroundLocation()),
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
        stopAudio()
        stopLocation(owner)
        service = null
        turnRunning = false
    }

    fun refresh() {
        val owner = service ?: return
        val active = turnRunning && !appVisible && RuntimeController.get(app).phase == RuntimeController.Phase.RUNNING
        if (active && audioEnabled) {
            if (audio == null) startAudio()
        } else stopAudio()
        if (active && locationEnabled && locationEnabledInSystem && hasBackgroundLocation()) {
            if (provider == null) startLocation(owner)
        } else stopLocation(owner)
    }

    private fun startAudio() {
        // A static loop needs no worker or timer. No audio focus, microphone, or media service type.
        val rate = 16_000
        var candidate: AudioTrack? = null
        try {
            val track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setBufferSizeInBytes(rate * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
            candidate = track
            check(track.write(ShortArray(rate), 0, rate) == rate)
            check(track.setLoopPoints(0, rate, -1) == AudioTrack.SUCCESS)
            track.play()
            check(track.playState == AudioTrack.PLAYSTATE_PLAYING)
            audio = track
            audioFailed = false
        } catch (_: RuntimeException) {
            candidate?.release()
            audioFailed = true
        }
    }

    private fun stopAudio() {
        audio?.release()
        audio = null
    }

    @SuppressLint("MissingPermission") // The caller checks coarse and background grants; a concurrent revocation is caught below.
    private fun startLocation(owner: DshService) {
        // Do not request GPS or read, retain, upload, or log any coordinate in the callback.
        val providers = location.getProviders(true)
        val selected = when {
            LocationManager.NETWORK_PROVIDER in providers -> LocationManager.NETWORK_PROVIDER
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && LocationManager.FUSED_PROVIDER in providers -> LocationManager.FUSED_PROVIDER
            else -> null
        }
        if (selected == null || !owner.setLocationForeground(true)) {
            locationFailed = true
            return
        }
        try {
            location.requestLocationUpdates(selected, 60_000L, 0f, this, Looper.getMainLooper())
            provider = selected
            locationFailed = false
        } catch (_: RuntimeException) {
            owner.setLocationForeground(false)
            locationFailed = true
        }
    }

    private fun stopLocation(owner: DshService) {
        if (provider == null) return
        location.removeUpdates(this)
        provider = null
        owner.setLocationForeground(false)
    }

    override fun onLocationChanged(location: Location) = Unit

    override fun onProviderDisabled(provider: String) {
        if (this.provider != provider) return
        service?.let(::stopLocation)
        refresh()
    }

    @Deprecated("Required by LocationListener on Android 10 and earlier")
    override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) = Unit

    override fun onProviderEnabled(provider: String) = Unit

    companion object {
        const val LOCATION_DISABLED = "android_background_location_services_disabled"
        private var instance: AndroidBackgroundProtection? = null
        fun get(context: Context): AndroidBackgroundProtection = instance
            ?: AndroidBackgroundProtection(context.applicationContext).also { instance = it }
    }
}
