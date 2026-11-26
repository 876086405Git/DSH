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
import android.util.Log

/** Each service owns its own resources. Main thread only. */
internal class SilentBackgroundAudio {
    private var audio: AudioTrack? = null
    val isPlaying get() = audio?.playState == AudioTrack.PLAYSTATE_PLAYING

    fun start(): Boolean {
        if (audio != null) return true
        // No worker, audio focus, microphone, or media service type.
        val rate = 16_000
        var candidate: AudioTrack? = null
        return try {
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
            true
        } catch (_: RuntimeException) {
            candidate?.release()
            false
        }
    }

    fun stop() {
        audio?.release()
        audio = null
    }
}

/** Owns a coarse provider subscription without inspecting or retaining coordinates. Main thread only. */
internal class ApproximateBackgroundLocation(
    private val app: Context,
    private val setForegroundType: (Boolean) -> Boolean,
    private val refresh: () -> Unit,
) : LocationListener {
    private val location by lazy { app.getSystemService(Context.LOCATION_SERVICE) as LocationManager }
    private var provider: String? = null

    val isRegistered get() = provider != null
    val enabledInSystem get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        location.isLocationEnabled
    } else {
        location.getProviders(true).any { it != LocationManager.PASSIVE_PROVIDER }
    }

    fun hasCoarseLocation(): Boolean = granted(Manifest.permission.ACCESS_COARSE_LOCATION)
    fun hasBackgroundLocation(): Boolean = hasCoarseLocation() &&
        (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION))
    private fun granted(permission: String): Boolean = app.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission") // Callers check both grants; concurrent revocation is caught below.
    fun start(): Boolean {
        if (isRegistered) return true
        val providers = location.getProviders(true)
        val selected = when {
            LocationManager.NETWORK_PROVIDER in providers -> LocationManager.NETWORK_PROVIDER
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && LocationManager.FUSED_PROVIDER in providers -> LocationManager.FUSED_PROVIDER
            else -> return false
        }
        if (!setForegroundType(true)) return false
        return try {
            location.requestLocationUpdates(selected, 60_000L, 0f, this, Looper.getMainLooper())
            provider = selected
            true
        } catch (_: RuntimeException) {
            setForegroundType(false)
            false
        }
    }

    fun stop(resetForegroundType: Boolean = true) {
        if (!isRegistered) return
        provider = null
        try {
            location.removeUpdates(this)
        } catch (e: RuntimeException) {
            Log.w("DshBackgroundLocation", "Could not remove location updates", e)
        } finally {
            if (resetForegroundType) setForegroundType(false)
        }
    }

    override fun onLocationChanged(location: Location) = Unit

    override fun onProviderDisabled(provider: String) {
        if (this.provider != provider) return
        stop()
        refresh()
    }

    @Deprecated("Required by LocationListener on Android 10 and earlier")
    override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) = Unit

    override fun onProviderEnabled(provider: String) = Unit
}
