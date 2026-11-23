package io.github.ccch1mneyyy.dsh_app.phone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.github.ccch1mneyyy.dsh_app.phone.a11y.PhoneA11yService
import java.time.LocalDate
import java.time.Instant
import java.time.ZoneId
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import org.json.JSONObject

/** The two local phone-channel entries for optional, read-only companionship. */
class CompanionScreenBridge(context: Context, private val control: PhoneControl, messenger: BinaryMessenger) {
    private val app = context.applicationContext
    private val shared = settings(app)
    private val owner = Any()
    private val main = Handler(Looper.getMainLooper())
    private val events = EventChannel(messenger, "dsh/companion_screen/state")
    private var sink: EventChannel.EventSink? = null
    @Volatile private var closed = false
    private data class Lease(val id: String, val generation: Long, val at: Long,
        val packageName: String, val accessibility: PhoneA11yService?)
    @Volatile private var latest: Lease? = null
    private val changed: () -> Unit = {
        main.post { if (!closed) sink?.success(snapshot()) }
    }

    init {
        shared.listeners.add(changed)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events; events.success(snapshot())
            }
            override fun onCancel(arguments: Any?) { sink = null }
        })
    }

    fun close() {
        if (closed) return
        closed = true
        latest = null
        shared.resident(owner, false)
        shared.listeners.remove(changed)
        events.setStreamHandler(null)
        sink = null
    }

    fun state(args: Map<*, *>?): Map<String, Any?> {
        if (closed) return mapOf("enabled" to false, "status" to "detached")
        when (args?.get("op") ?: "get") {
            "get" -> {}
            "resident" -> shared.resident(owner, args?.get("active") == true)
            "configure" -> {
                val was = shared.enabled
                if (!shared.configure(args!!)) return snapshot() + mapOf("error" to "invalid_or_unsaved_settings")
                if (!was && shared.enabled && !PhoneA11yService.isConnected()) requestProjection()
            }
            "pause" -> shared.pause()
            "mute" -> shared.mute()
            "request_projection" -> requestProjection()
            "request_usage_access" -> {
                app.startActivity(Intent(android.provider.Settings.ACTION_USAGE_ACCESS_SETTINGS)
                    .setData(android.net.Uri.parse("package:${app.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            "permit" -> {
                val lease = latest
                val tier = args?.get("tier") as? String
                val allowed = lease != null && args?.get("sample_id") == lease.id && current(lease) &&
                    (tier == "cheap" || tier == "serious") && shared.reserve(tier!!)
                return snapshot() + mapOf("allowed" to allowed)
            }
            "note" -> (args?.get("scene") as? String)?.let(shared::note)
            "cost" -> {
                val id = args?.get("request_id") as? String
                val at = (args?.get("at_ms") as? Number)?.toLong()
                val amount = (args?.get("estimated_cny") as? Number)?.toDouble()
                if (id != null && at != null && (amount == null || amount.isFinite() && amount >= 0)) {
                    shared.cost(id, at, amount)
                }
            }
            else -> return snapshot() + mapOf("error" to "invalid_operation")
        }
        return snapshot()
    }

    /** PhonePlugin calls this on its existing blocking-work lane, never main. */
    fun sample(args: Map<*, *>? = null): Map<String, Any?> {
        val validation = args?.get("validate")
        if (validation != null) {
            val lease = latest
            if (validation !is String || lease == null || lease.id != validation || !current(lease)) return status("stale")
            val requireIdle = args?.get("require_idle") == true
            val valid = if (lease.accessibility != null) {
                PhoneA11yService.instance === lease.accessibility &&
                    lease.accessibility.companionScreenCurrent(control, shared.excluded, lease.packageName, requireIdle)
            } else !requireIdle && CompanionScreenProjectionService.permitsCurrent(app, control, shared.excluded, lease.packageName)
            return status(if (valid && current(lease)) "valid" else "stale")
        }
        if (args != null && args.isNotEmpty() && (args.keys.any { it !in setOf("image", "generation") } ||
            args["image"] !is Boolean)) return status("invalid_arguments")
        val generation = shared.generation
        val image = args?.get("image") == true
        val requestedGeneration = args?.get("generation")
        if (image && ((requestedGeneration as? Number)?.toLong() != generation ||
            requestedGeneration !is Int && requestedGeneration !is Long)) return status("stale")
        if (image && (!shared.visionEnabled || shared.visionSelection == null || shared.visionHost == null))
            return status("image_not_enabled")
        fun live() = !closed && shared.active(owner, generation) && !control.isLocked()
        if (!live()) return status("inactive")
        val service = PhoneA11yService.instance
        val result = if (service != null) service.companionScreenSample(control, shared.excluded, ::live, image)
            else CompanionScreenProjectionService.sample(app, control, shared.excluded, ::live)
        if (!live()) return status("inactive")
        if (result["status"] != "observed") return result
        val pkg = result["package_name"] as? String ?: return status("unknown_application")
        val lease = Lease(UUID.randomUUID().toString(), generation, System.currentTimeMillis(), pkg, service)
        latest = lease
        // UsageEvents/OCR do not establish all pixel sources without a11y.
        // Projection keeps its original text-only capability after opt-in.
        return result + mapOf("sample_id" to lease.id) + if (image && service == null)
            mapOf("image" to null, "image_status" to "source_metadata_unavailable") else emptyMap()
    }

    private fun current(lease: Lease): Boolean {
        val now = System.currentTimeMillis()
        return !closed && latest === lease && now >= lease.at && now - lease.at <= 60000 &&
            shared.active(owner, lease.generation) && !control.isLocked()
    }

    private fun requestProjection() {
        if (!shared.active(owner, shared.generation)) return
        // Each explicit enable/retry asks the system for a new session. No
        // cached consent Intent or automatic restart is reused.
        CompanionScreenProjectionService.stop(app)
        shared.beginCapture()
        try {
            app.startActivity(Intent(app, CompanionScreenProjectionActivity::class.java)
                .putExtra("generation", shared.captureGeneration).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) { shared.signal() }
    }

    private fun snapshot(): Map<String, Any?> = shared.snapshot() + mapOf(
        "accessibility" to PhoneA11yService.isConnected(),
        "image_capture_supported" to (PhoneA11yService.isConnected() && Build.VERSION.SDK_INT in 34..37),
        "projection_active" to CompanionScreenProjectionService.running,
        "usage_access" to CompanionScreenProjectionService.hasUsageAccess(app))

    private fun status(value: String): Map<String, Any?> = mapOf("status" to value)

    companion object {
        @Volatile private var state: ScreenSettings? = null
        private fun settings(context: Context): ScreenSettings = state ?: synchronized(this) {
            state ?: ScreenSettings(context.applicationContext).also { state = it }
        }
        fun isEnabled(context: Context): Boolean = settings(context).enabled
        fun pause(context: Context) = settings(context).pause()
        internal fun generation(context: Context): Long = settings(context).captureGeneration
        internal fun captureAllowed(context: Context, generation: Long): Boolean = settings(context).captureActive(generation)
        internal fun changed(context: Context) = settings(context).signal()
        internal fun captureEnded(context: Context, generation: Long) = settings(context).captureEnded(generation)
    }
}

class CompanionScreenPauseReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_PAUSE) CompanionScreenBridge.pause(context)
    }
    companion object { const val ACTION_PAUSE = "io.github.ccch1mneyyy.dsh_app.COMPANION_SCREEN_PAUSE" }
}

/** One process authority backed by settings; capture pixels/text are never persisted. */
private class ScreenSettings(private val app: Context) {
    private val prefs = app.getSharedPreferences("companion_screen", Context.MODE_PRIVATE)
    private val lock = Any()
    val listeners = CopyOnWriteArrayList<() -> Unit>()
    @Volatile var enabled = prefs.getBoolean("enabled", false)
        private set
    @Volatile var visionEnabled = prefs.getBoolean("vision_enabled", false)
        private set
    @Volatile var visionSelection = readVisionSelection(prefs.getString("vision_selection", null))
        private set
    @Volatile var visionHost = prefs.getString("vision_host", null)?.takeIf { validChoice(it, 512) }
        private set
    @Volatile var generation = 0L
        private set
    /** A settings change invalidates model observations, not a live OS consent. */
    @Volatile var captureGeneration = 0L
        private set
    @Volatile var excluded = prefs.getStringSet("excluded_packages", DEFAULT_EXCLUDED)!!.toSet()
        private set
    private var residentOwner: Any? = null
    private var frequency = prefs.getString("frequency", "normal")!!
    private var seriousPerHour = prefs.getInt("serious_per_hour", 6)
    private var mutedUntil = prefs.getLong("muted_until_ms", 0)
    private var day = prefs.getString("activity_day", "")!!
    private var activities = prefs.getStringSet("activities", emptySet())!!.toSet()
    private var cheap = readTimes("cheap")
    private var serious = readTimes("serious")
    private var costDay = prefs.getString("cost_day", "")!!
    private var costs = runCatching { JSONObject(prefs.getString("costs", "{}")!!) }.getOrElse { JSONObject() }

    private fun readTimes(key: String): MutableList<Long> = prefs.getString(key, "")!!.split(',')
        .mapNotNull { it.toLongOrNull() }.toMutableList()

    fun signal() { listeners.forEach { it() } }

    fun beginCapture() {
        synchronized(lock) { generation++; captureGeneration++ }
        signal()
    }

    fun captureEnded(expected: Long) {
        val changed = synchronized(lock) {
            if (captureGeneration != expected) false else { generation++; captureGeneration++; true }
        }
        if (changed) signal()
    }

    fun captureActive(epoch: Long): Boolean = synchronized(lock) {
        residentOwner != null && enabled && epoch == captureGeneration && System.currentTimeMillis() >= mutedUntil
    }

    fun active(owner: Any, epoch: Long): Boolean = synchronized(lock) {
        residentOwner === owner && active(epoch)
    }

    fun active(epoch: Long): Boolean = synchronized(lock) {
        residentOwner != null && enabled && epoch == generation && System.currentTimeMillis() >= mutedUntil
    }

    fun resident(owner: Any, active: Boolean) {
        val changed = synchronized(lock) {
            if (active) {
                if (residentOwner === owner) false else { residentOwner = owner; generation++; captureGeneration++; true }
            } else if (residentOwner === owner) { residentOwner = null; generation++; captureGeneration++; true } else false
        }
        if (changed) {
            if (!active) CompanionScreenProjectionService.stop(app)
            signal()
        }
    }

    fun configure(args: Map<*, *>): Boolean {
        val result = synchronized(lock) {
            if (args.keys.any { it !in setOf("op", "enabled", "frequency", "excluded_packages", "serious_per_hour",
                    "vision_enabled", "vision_selection", "vision_host") }) return false
            val on = args["enabled"] ?: enabled
            val pictures = args["vision_enabled"] ?: visionEnabled
            val selected = if (args.containsKey("vision_selection"))
                readVisionSelection(args["vision_selection"]) ?: return false else visionSelection
            val host = args["vision_host"] ?: visionHost
            val mode = args["frequency"] ?: frequency
            val apps = args["excluded_packages"] ?: excluded.toList()
            val limit = args["serious_per_hour"] ?: seriousPerHour
            if (on !is Boolean || pictures !is Boolean || host != null && (host !is String || !validChoice(host, 512)) ||
                mode !in setOf("quiet", "normal", "chatty") || apps !is List<*> ||
                apps.any { it !is String || it.isBlank() } || limit !is Int || limit !in 0..60) return false
            val packages = apps.map { it as String }.toSet()
            val selectedHost = host as String?
            val saved = prefs.edit().putBoolean("enabled", on).putString("frequency", mode as String)
                .putBoolean("vision_enabled", pictures).putString("vision_selection", selected?.let { JSONObject(it).toString() })
                .putString("vision_host", selectedHost)
                .putStringSet("excluded_packages", packages).putInt("serious_per_hour", limit).commit()
            if (!saved) { enabled = false; generation++; captureGeneration++; return@synchronized false }
            if (enabled != on) captureGeneration++
            visionEnabled = pictures; visionSelection = selected; visionHost = selectedHost
            enabled = on; frequency = mode; excluded = packages; seriousPerHour = limit; generation++
            true
        }
        if (!enabled) CompanionScreenProjectionService.stop(app)
        signal()
        return result
    }

    fun pause() {
        synchronized(lock) { enabled = false; generation++; captureGeneration++; prefs.edit().putBoolean("enabled", false).commit() }
        CompanionScreenProjectionService.stop(app)
        signal()
    }

    fun mute() {
        synchronized(lock) {
            mutedUntil = System.currentTimeMillis() + 3600000; generation++; captureGeneration++
            prefs.edit().putLong("muted_until_ms", mutedUntil).commit()
        }
        CompanionScreenProjectionService.stop(app)
        signal()
    }

    /** Persist the physical-attempt slot before allowing the caller to send. */
    fun reserve(tier: String): Boolean = synchronized(lock) {
        val now = System.currentTimeMillis()
        val entries = (if (tier == "cheap") cheap else serious).filter { it > now - 3600000 }.toMutableList()
        val limit = if (tier == "cheap") 30 else seriousPerHour
        if (entries.size >= limit) return false
        entries.add(now)
        if (!prefs.edit().putString(tier, entries.joinToString(",")).commit()) return false
        if (tier == "cheap") cheap = entries else serious = entries
        true
    }

    fun note(scene: String) {
        if (scene !in SCENES) return
        synchronized(lock) {
            rollDay()
            activities = activities + scene
            prefs.edit().putString("activity_day", day).putStringSet("activities", activities).apply()
        }
        signal()
    }

    fun snapshot(): Map<String, Any?> = synchronized(lock) {
        rollDay()
        val values = costs.keys().asSequence().map { costs.opt(it) }.toList()
        val estimated = if (values.any { it !is Number }) null else values.sumOf { (it as Number).toDouble() }
        mapOf("enabled" to enabled, "generation" to generation, "resident_active" to (residentOwner != null),
            "vision_enabled" to visionEnabled, "vision_selection" to visionSelection, "vision_host" to visionHost,
            "frequency" to frequency, "excluded_packages" to excluded.sorted(), "serious_per_hour" to seriousPerHour,
            "muted_until_ms" to mutedUntil,
            "today_activities" to activities.sorted(),
            "today_estimated_cny" to estimated)
    }

    fun cost(id: String, at: Long, amount: Double?) {
        val today = LocalDate.now().toString()
        if (Instant.ofEpochMilli(at).atZone(ZoneId.systemDefault()).toLocalDate().toString() != today) return
        synchronized(lock) {
            rollDay()
            // Revisions replace the same request estimate; they are not added twice.
            costs.put(id, amount ?: JSONObject.NULL)
            prefs.edit().putString("cost_day", costDay).putString("costs", costs.toString()).apply()
        }
        signal()
    }

    /** Drop yesterday's local summary on first access, including after restart. */
    private fun rollDay() {
        val today = LocalDate.now().toString()
        if (day == today && costDay == today) return
        if (day != today) { day = today; activities = emptySet() }
        if (costDay != today) { costDay = today; costs = JSONObject() }
        prefs.edit().putString("activity_day", day).putStringSet("activities", activities)
            .putString("cost_day", costDay).putString("costs", costs.toString()).apply()
    }

    companion object {
        private fun validChoice(value: String, limit: Int = 256): Boolean = value.isNotBlank() &&
            value.length <= limit && value.none { it < ' ' || it == '\u007f' }
        private fun readVisionSelection(value: Any?): Map<String, String>? {
            val map = when (value) {
                is Map<*, *> -> value
                is String -> runCatching { JSONObject(value).let { json ->
                    json.keys().asSequence().associateWith { json.get(it) }
                } }.getOrNull()
                else -> null
            } ?: return null
            if (map.keys.any { it !in setOf("provider", "model", "reasoningEffort") } ||
                map["provider"] !is String || map["model"] !is String ||
                map.values.any { it !is String || !validChoice(it) }) return null
            return map.entries.associate { it.key as String to it.value as String }
        }
        // Existing PhonePolicies continue to supply banks/payment exclusions.
        // These are only the additional screen-companionship defaults.
        val DEFAULT_EXCLUDED = setOf("com.tencent.mm", "com.tencent.mobileqq", "com.whatsapp",
            "org.telegram.messenger", "org.thoughtcrime.securesms")
        val SCENES = setOf("gaming", "coding", "video", "reading", "chatting", "idle", "other")
    }
}
