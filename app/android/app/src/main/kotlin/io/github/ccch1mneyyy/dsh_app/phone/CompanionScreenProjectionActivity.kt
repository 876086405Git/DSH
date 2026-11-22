package io.github.ccch1mneyyy.dsh_app.phone

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle

/** One explicit system consent, bound to the still-current companion request. */
class CompanionScreenProjectionActivity : Activity() {
    private var generation = Long.MIN_VALUE
    private var requested = false
    private var handedOff = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        generation = intent.getLongExtra("generation", Long.MIN_VALUE)
        requested = savedInstanceState?.getBoolean("requested") == true
        if (!CompanionScreenBridge.captureAllowed(this, generation)) { finish(); return }
        if (requested) return
        requested = true
        try {
            val manager = getSystemService(MediaProjectionManager::class.java)
            val consent = if (Build.VERSION.SDK_INT >= 34) {
                manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
            } else manager.createScreenCaptureIntent()
            startActivityForResult(consent, REQUEST)
        } catch (_: Exception) {
            CompanionScreenBridge.captureEnded(this, generation)
            finish()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("requested", requested)
        super.onSaveInstanceState(outState)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST || handedOff) return
        if (resultCode != RESULT_OK || data == null ||
            !CompanionScreenBridge.captureAllowed(this, generation)) {
            CompanionScreenBridge.captureEnded(this, generation)
            finish()
            return
        }
        try {
            // This Intent is delivered once. It is never saved in preferences,
            // a file, or a static field, nor reused after this service ends.
            startForegroundService(Intent(this, CompanionScreenProjectionService::class.java)
                .putExtra("generation", generation).putExtra("result_code", resultCode)
                .putExtra("result_data", data))
            handedOff = true
        } catch (_: Exception) {
            CompanionScreenBridge.captureEnded(this, generation)
        }
        finish()
    }

    override fun onDestroy() {
        if (isFinishing && !handedOff) CompanionScreenBridge.captureEnded(this, generation)
        super.onDestroy()
    }

    companion object { private const val REQUEST = 1 }
}
