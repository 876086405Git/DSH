package io.github.ccch1mneyyy.dsh_app.phone

import android.app.Activity
import android.app.AppOpsManager
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.view.Display
import android.view.WindowManager
import io.github.ccch1mneyyy.dsh_app.companion.CompanionConversationNotification
import io.github.ccch1mneyyy.dsh_app.phone.a11y.CompanionScreenChange
import io.github.ccch1mneyyy.dsh_app.phone.a11y.LocalOcrBoundary
import io.github.ccch1mneyyy.dsh_app.phone.a11y.LocalOcrResult
import io.github.ccch1mneyyy.dsh_app.phone.a11y.MlKitLocalOcr
import io.github.ccch1mneyyy.dsh_app.phone.a11y.ProtectedPages
import io.github.ccch1mneyyy.dsh_app.phone.a11y.ScreenMask
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

/**
 * A single-use, read-only projection owned by the resident companion process.
 * No image leaves native memory and no Phone action session is created.
 *
 * UsageEvents gives observed foreground activity identity, not window/secure
 * metadata or pixel provenance. Ambiguity fails closed; OCR is never claimed to
 * prove a page safe. The accessibility path remains preferable when available.
 */
class CompanionScreenProjectionService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var thread: HandlerThread
    private lateinit var worker: Handler
    private val ended = AtomicBoolean(false)
    private val frameLock = Any()
    private val sampleLock = Any()
    @Volatile private var generation = Long.MIN_VALUE
    @Volatile private var projecting = false
    @Volatile private var visible = true
    @Volatile private var defaultDisplayScope = false
    private var consumed = false
    private var foreground = false
    private var receiverRegistered = false
    private var displayRegistered = false
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var latestImage: Image? = null
    private var imageAt = 0L
    private var frameEpoch = 0L
    private var captureWidth = 0
    private var captureHeight = 0
    private var lastSampleAt = Long.MIN_VALUE
    private var sampledEpoch = Long.MIN_VALUE
    private var sampledApp: AppIdentity? = null
    private val changes = CompanionScreenChange()
    private var validation: Validation? = null
    private val ocr by lazy { MlKitLocalOcr.get(applicationContext) }

    private data class AppIdentity(val packageName: String, val activity: String, val at: Long)
    private data class Validation(val app: AppIdentity, val epoch: Long, val at: Long, val grid: ByteArray)
    private data class Frame(val epoch: Long, val grid: ByteArray, val bitmap: Bitmap?)

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() { end() }
        override fun onCapturedContentVisibilityChanged(isVisible: Boolean) {
            visible = isVisible
            synchronized(frameLock) { frameEpoch++; clearImageLocked() }
        }
        override fun onCapturedContentResize(width: Int, height: Int) {
            resize(width, height)
        }
    }
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {
            if (displayId == Display.DEFAULT_DISPLAY) end()
        }
        override fun onDisplayChanged(displayId: Int) {
            if (displayId != Display.DEFAULT_DISPLAY || ended.get()) return
            val size = displaySize()
            if (Build.VERSION.SDK_INT < 34) resize(size.x, size.y)
            else if (captureWidth != size.x || captureHeight != size.y) {
                // Wait for the projection's own resize callback; do not treat a
                // transient rotation as a new consent or create another VD.
                defaultDisplayScope = false
                synchronized(frameLock) { frameEpoch++; clearImageLocked() }
            } else defaultDisplayScope = true
        }
    }
    private val screenOff = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_OFF) end()
        }
    }
    private val watch = object : Runnable {
        override fun run() {
            if (ended.get()) return
            if (!allowed() || PhoneControl.get(applicationContext).isLocked()) { end(); return }
            worker.postDelayed(this, 2000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        thread = HandlerThread("companion-screen-capture").apply { start() }
        worker = Handler(thread.looper)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nextGeneration = intent?.getLongExtra("generation", Long.MIN_VALUE) ?: Long.MIN_VALUE
        val code = intent?.getIntExtra("result_code", Activity.RESULT_CANCELED) ?: Activity.RESULT_CANCELED
        val data = if (Build.VERSION.SDK_INT >= 33) intent?.getParcelableExtra("result_data", Intent::class.java)
            else intent?.getParcelableExtra<Intent>("result_data")
        if (consumed || ended.get()) {
            CompanionScreenBridge.captureEnded(this, nextGeneration)
            end()
            return START_NOT_STICKY
        }
        consumed = true
        generation = nextGeneration
        if (code != Activity.RESULT_OK || data == null || !allowed() ||
            PhoneControl.get(applicationContext).isLocked()) {
            end()
            return START_NOT_STICKY
        }
        instance = this
        try {
            CompanionConversationNotification.startForeground(this) { notification ->
                if (Build.VERSION.SDK_INT >= 29) {
                    startForeground(CompanionConversationNotification.ID, notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
                } else startForeground(CompanionConversationNotification.ID, notification)
            }
            foreground = true
            val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenOff, filter, RECEIVER_NOT_EXPORTED)
            else registerReceiver(screenOff, filter)
            receiverRegistered = true
            getSystemService(DisplayManager::class.java).registerDisplayListener(displayListener, worker)
            displayRegistered = true
            worker.post { startCapture(code, data) }
        } catch (_: Exception) { end() }
        return START_NOT_STICKY
    }

    private fun allowed(): Boolean = !ended.get() &&
        CompanionScreenBridge.captureAllowed(applicationContext, generation)

    private fun startCapture(code: Int, data: Intent) {
        if (!allowed()) { end(); return }
        try {
            val manager = getSystemService(MediaProjectionManager::class.java)
            val capture = manager.getMediaProjection(code, data) ?: run { end(); return }
            projection = capture
            capture.registerCallback(projectionCallback, worker)
            val size = displaySize()
            if (size.x <= 0 || size.y <= 0) { end(); return }
            captureWidth = size.x
            captureHeight = size.y
            defaultDisplayScope = true
            val surface = newReader(size.x, size.y)
            synchronized(frameLock) { reader = surface; frameEpoch++ }
            // Exactly one createVirtualDisplay per system consent.
            virtualDisplay = capture.createVirtualDisplay("companion-screen",
                surface.width, surface.height, resources.configuration.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface.surface, null, worker)
            if (!allowed()) { end(); return }
            projecting = true
            CompanionScreenBridge.changed(applicationContext)
            worker.post(watch)
        } catch (_: Exception) { end() }
    }

    /** Callback lane only. Rotation reuses the same token and virtual display. */
    private fun resize(width: Int, height: Int) {
        if (!allowed() || width <= 0 || height <= 0) return
        val current = virtualDisplay ?: return
        val size = displaySize()
        defaultDisplayScope = width == size.x && height == size.y
        if (width == captureWidth && height == captureHeight) return
        try {
            val replacement = newReader(width, height)
            synchronized(frameLock) {
                frameEpoch++
                clearImageLocked()
                val old = reader
                reader = replacement
                try {
                    current.setSurface(null)
                    current.resize(replacement.width, replacement.height, resources.configuration.densityDpi)
                    current.setSurface(replacement.surface)
                } finally {
                    old?.setOnImageAvailableListener(null, null)
                    old?.close()
                }
                captureWidth = width
                captureHeight = height
            }
        } catch (_: Exception) { end() }
    }

    private fun newReader(width: Int, height: Int): ImageReader {
        // Bound local OCR allocation while preserving the captured aspect ratio.
        val scale = minOf(1.0, 1280.0 / maxOf(width, height))
        val w = (width * scale).roundToInt().coerceAtLeast(1)
        val h = (height * scale).roundToInt().coerceAtLeast(1)
        return ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3).also { created ->
            created.setOnImageAvailableListener({ source ->
                val image = try { source.acquireLatestImage() } catch (_: Exception) { null }
                if (image != null) synchronized(frameLock) {
                    if (!allowed() || source !== reader || !visible || !defaultDisplayScope) image.close()
                    else {
                        latestImage?.close()
                        latestImage = image
                        imageAt = System.currentTimeMillis()
                    }
                }
            }, worker)
        }
    }

    @Suppress("DEPRECATION")
    private fun displaySize(): Point {
        if (Build.VERSION.SDK_INT >= 30) {
            val bounds = getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds
            return Point(bounds.width(), bounds.height())
        }
        return Point().also {
            getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)?.getRealSize(it)
        }
    }

    /** Called only from PhonePlugin's existing worker, not from the UI thread. */
    private fun read(control: PhoneControl, excluded: Set<String>, current: () -> Boolean): Map<String, Any?> =
        synchronized(sampleLock) {
            if (Looper.myLooper() == Looper.getMainLooper()) return@synchronized status("worker_required")
            fun live() = instance === this && projecting && allowed() && current() && visible &&
                defaultDisplayScope && !control.isLocked()
            if (!live()) return@synchronized status("inactive")
            if (control.shownControls() != null) return@synchronized status("phone_busy")
            if (!hasUsageAccess(this)) return@synchronized status("usage_access_required")
            val app = currentApplication(this) ?: return@synchronized status("unknown_application")
            if (!permitted(control, excluded, app.packageName)) return@synchronized status("protected")
            val now = SystemClock.uptimeMillis()
            if (lastSampleAt != Long.MIN_VALUE && now >= lastSampleAt && now - lastSampleAt < 2000)
                return@synchronized status("unchanged")
            lastSampleAt = now
            val epoch = ocr.enabledEpoch() ?: return@synchronized status("ocr_unavailable")
            val frame = try { frame(app, now) } catch (_: Exception) { null }
                ?: return@synchronized status("capture_unavailable")
            val bitmap = frame.bitmap ?: return@synchronized status("unchanged")
            validation = null
            // The shared OCR callback polls frequently. Keep its cancellation
            // check cheap; query actual foreground identity on either side of
            // OCR, before any recognized text may leave this native method.
            fun fastCurrent() = live() && ocr.enabledEpoch() == epoch &&
                synchronized(frameLock) { frameEpoch == frame.epoch }
            fun stillCurrent() = fastCurrent() && currentApplication(this) == app &&
                permitted(control, excluded, app.packageName)
            try {
                if (!stillCurrent()) return@synchronized status("changed")
                val deadline = SystemClock.uptimeMillis() + 3500
                val result = LocalOcrBoundary.read(true, true, bitmap.width, bitmap.height,
                    deadline, SystemClock::uptimeMillis, { !fastCurrent() }) {
                    ocr.recognize(bitmap, deadline) { !fastCurrent() }
                }
                if (!stillCurrent()) return@synchronized status("changed")
                val lines = (result as? LocalOcrResult.Recognized)?.lines?.map { it.text }
                    ?: return@synchronized status("ocr_unavailable")
                if (lines.isEmpty() || lines.all { it.isBlank() } ||
                    lines.any { SafetyRules.isSecret(it) || ScreenMask.mask(it) != it } ||
                    ProtectedPages.isProtected(app.packageName, lines.take(8)))
                    return@synchronized status("protected")
                val text = lines.joinToString("\n").take(3000)
                val filtered = control.core.safety.filterScreen(ScreenSnapshot(
                    "companion-projection", text, null, app.packageName, readPackages = setOf(app.packageName)))
                if (!stillCurrent() || filtered.text != text) return@synchronized status("protected")
                validation = Validation(app, frame.epoch, SystemClock.uptimeMillis(), frame.grid.copyOf())
                mapOf("status" to "observed", "observed_at_ms" to System.currentTimeMillis(),
                    "package_name" to app.packageName, "capture_method" to "ocr", "text" to text,
                    // There is no accessibility keyboard/activity signal. Unknown
                    // stays unknown; the Dart serious-comment gate treats it busy.
                    "busy" to null)
            } finally { bitmap.recycle() }
        }

    private fun frame(app: AppIdentity, now: Long): Frame? = synchronized(frameLock) {
        val image = latestImage ?: return@synchronized null
        if (imageAt < app.at || !visible || !defaultDisplayScope) return@synchronized null
        if (sampledEpoch != frameEpoch) {
            changes.clear()
            sampledEpoch = frameEpoch
            sampledApp = null
        }
        val grid = grid(image)
        if (blank(grid)) return@synchronized null
        val due = changes.changed(grid, now, sampledApp != app)
        sampledApp = app
        Frame(frameEpoch, grid, if (due) bitmap(image) else null)
    }

    private fun validate(control: PhoneControl, excluded: Set<String>, pkg: String): Boolean = synchronized(sampleLock) {
        if (Looper.myLooper() == Looper.getMainLooper()) return@synchronized false
        val previous = validation ?: return@synchronized false
        fun live() = instance === this && projecting && allowed() && visible && defaultDisplayScope &&
            !control.isLocked() && control.shownControls() == null
        val now = SystemClock.uptimeMillis()
        if (!live() || previous.app.packageName != pkg || now < previous.at || now - previous.at > 60000 ||
            !permitted(control, excluded, pkg) || currentApplication(this) != previous.app) return@synchronized false
        val same = try {
            synchronized(frameLock) {
                val image = latestImage
                image != null && imageAt >= previous.app.at && frameEpoch == previous.epoch &&
                    grid(image).contentEquals(previous.grid)
            }
        } catch (_: Exception) { false }
        same && live() && currentApplication(this) == previous.app && permitted(control, excluded, pkg)
    }

    private fun grid(image: Image): ByteArray {
        val plane = image.planes[0]
        val pixels = plane.buffer
        val width = CompanionScreenChange.WIDTH
        val height = CompanionScreenChange.HEIGHT
        return ByteArray(width * height) { index ->
            val x = ((index % width + 0.5) * image.width / width).toInt().coerceAtMost(image.width - 1)
            val y = ((index / width + 0.5) * image.height / height).toInt().coerceAtMost(image.height - 1)
            val at = y * plane.rowStride + x * plane.pixelStride
            val r = pixels.get(at).toInt() and 255
            val g = pixels.get(at + 1).toInt() and 255
            val b = pixels.get(at + 2).toInt() and 255
            ((77 * r + 150 * g + 29 * b) shr 8).toByte()
        }
    }

    private fun blank(grid: ByteArray): Boolean {
        var low = 255
        var high = 0
        for (value in grid) { val n = value.toInt() and 255; low = minOf(low, n); high = maxOf(high, n) }
        // Android omits FLAG_SECURE pixels; a black/flat capture is no evidence
        // of readable content. Partial secure/overlay metadata is unavailable.
        return high < 12 || high - low < 6
    }

    private fun bitmap(image: Image): Bitmap {
        val plane = image.planes[0]
        val pixels = plane.buffer
        val colors = IntArray(image.width * image.height)
        for (y in 0 until image.height) for (x in 0 until image.width) {
            val at = y * plane.rowStride + x * plane.pixelStride
            colors[y * image.width + x] = Color.rgb(pixels.get(at).toInt() and 255,
                pixels.get(at + 1).toInt() and 255, pixels.get(at + 2).toInt() and 255)
        }
        return Bitmap.createBitmap(colors, image.width, image.height, Bitmap.Config.ARGB_8888)
    }

    private fun clearImageLocked() {
        val image = latestImage
        latestImage = null
        imageAt = 0
        runCatching { image?.close() }
    }

    private fun end() {
        if (!ended.compareAndSet(false, true)) return
        projecting = false
        CompanionScreenBridge.captureEnded(applicationContext, generation)
        if (instance === this) instance = null
        worker.post {
            worker.removeCallbacks(watch)
            runCatching { virtualDisplay?.release() }
            virtualDisplay = null
            synchronized(frameLock) {
                frameEpoch++
                clearImageLocked()
                runCatching { reader?.setOnImageAvailableListener(null, null) }
                runCatching { reader?.close() }
                reader = null
            }
            projection?.let { capture ->
                runCatching { capture.unregisterCallback(projectionCallback) }
                runCatching { capture.stop() }
            }
            projection = null
            thread.quitSafely()
            main.post { stopSelf() }
        }
    }

    override fun onDestroy() {
        end()
        if (receiverRegistered) { unregisterReceiver(screenOff); receiverRegistered = false }
        if (displayRegistered) {
            getSystemService(DisplayManager::class.java).unregisterDisplayListener(displayListener)
            displayRegistered = false
        }
        // Shared ID belongs to the resident conversation as well. Do not remove
        // its notification when just this optional projection ends.
        if (foreground) stopForeground(STOP_FOREGROUND_DETACH)
        super.onDestroy()
    }

    companion object {
        @Volatile private var instance: CompanionScreenProjectionService? = null
        val running: Boolean get() = instance?.let { it.projecting && it.allowed() } == true

        fun stop(context: Context) {
            instance?.end()
            context.stopService(Intent(context, CompanionScreenProjectionService::class.java))
        }

        fun sample(context: Context, control: PhoneControl, excluded: Set<String>,
                   current: () -> Boolean): Map<String, Any?> =
            instance?.takeIf { it.applicationContext.packageName == context.applicationContext.packageName }
                ?.read(control, excluded, current) ?: status("projection_required")

        fun permitsCurrent(context: Context, control: PhoneControl, excluded: Set<String>, pkg: String): Boolean =
            instance?.takeIf { it.applicationContext.packageName == context.applicationContext.packageName }
                ?.validate(control, excluded, pkg) == true

        @Suppress("DEPRECATION")
        fun hasUsageAccess(context: Context): Boolean = try {
            val ops = context.getSystemService(AppOpsManager::class.java)
            val mode = if (Build.VERSION.SDK_INT >= 29)
                ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
            else ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
            mode == AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) { false }

        private fun permitted(control: PhoneControl, excluded: Set<String>, pkg: String): Boolean =
            pkg !in excluded && pkg !in ProtectedPages.packages && pkg !in ProtectedPages.settingsPackages &&
                !SafetyRules.isSystemPackage(pkg) && control.core.safety.checkRead(pkg, null) == null

        @Suppress("DEPRECATION")
        private fun currentApplication(context: Context): AppIdentity? {
            if (!hasUsageAccess(context)) return null
            return try {
                val now = System.currentTimeMillis()
                val events = context.getSystemService(UsageStatsManager::class.java)
                    .queryEvents((now - 86400000).coerceAtLeast(0), now + 1) ?: return null
                val active = LinkedHashMap<Pair<String, String>, AppIdentity>()
                val event = UsageEvents.Event()
                var count = 0
                while (events.hasNextEvent()) {
                    if (++count > 20000) return null
                    events.getNextEvent(event)
                    val pkg = event.packageName ?: continue
                    val activity = event.className ?: continue
                    val key = pkg to activity
                    when (event.eventType) {
                        UsageEvents.Event.MOVE_TO_FOREGROUND -> active[key] = AppIdentity(pkg, activity, event.timeStamp)
                        UsageEvents.Event.MOVE_TO_BACKGROUND -> active.remove(key)
                        // ACTIVITY_STOPPED is API29; its numeric event value is
                        // not used on older platforms.
                        else -> if (Build.VERSION.SDK_INT >= 29 && event.eventType == UsageEvents.Event.ACTIVITY_STOPPED)
                            active.remove(key)
                    }
                }
                // Multi-resume, unknown identity, or an activity absent from the
                // retained UsageEvents window supplies no capture permission.
                active.values.singleOrNull()
            } catch (_: Exception) { null }
        }

        private fun status(value: String): Map<String, Any?> = mapOf("status" to value)
    }
}
