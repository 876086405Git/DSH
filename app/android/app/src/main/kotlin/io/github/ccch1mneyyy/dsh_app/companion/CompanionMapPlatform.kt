package io.github.ccch1mneyyy.dsh_app.companion

import android.app.Activity
import android.app.KeyguardManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import io.github.ccch1mneyyy.dsh_app.phone.AppVisibility
import io.github.ccch1mneyyy.dsh_app.phone.NavUris
import io.github.ccch1mneyyy.dsh_app.phone.SystemHandlers

internal data class CompanionMapTarget(
    val packageName: String, val componentName: String, val uid: Int, val label: String?,
) {
    fun value(): Map<String, Any?> = mapOf("packageName" to packageName,
        "componentName" to componentName, "uid" to uid, "label" to label)
}

internal data class CompanionMapArgument(
    val address: String, val targetKind: String, val target: CompanionMapTarget?,
)

internal data class CompanionMapObservation(
    val result: String, val state: String, val event: String, val outcome: String,
    val reason: String? = null,
)

/** The only URI builder used by this fixed action. Location text is one encoded value. */
internal object CompanionMapAddress {
    fun uri(address: String): String {
        require(address.isNotBlank() && '\u0000' !in address)
        for (i in address.indices) {
            if (Character.isHighSurrogate(address[i]))
                require(i + 1 < address.length && Character.isLowSurrogate(address[i + 1]))
            if (Character.isLowSurrogate(address[i]))
                require(i > 0 && Character.isHighSurrogate(address[i - 1]))
        }
        return "geo:0,0?q=" + NavUris.enc(address)
    }
}

internal class CompanionMapPlatform(private val context: Context) {
    private val packages get() = context.packageManager

    private fun intent(address: String) = Intent(Intent.ACTION_VIEW, Uri.parse(CompanionMapAddress.uri(address)))

    fun foreground(activity: Activity): Boolean = !activity.isFinishing && !activity.isDestroyed &&
        AppVisibility.isResumed(activity) &&
        !context.getSystemService(KeyguardManager::class.java).isKeyguardLocked &&
        context.getSystemService(PowerManager::class.java).isInteractive

    private fun enabled(info: ActivityInfo): Boolean = info.exported && info.applicationInfo.enabled &&
        SystemHandlers.componentEnabled(info.enabled) {
            packages.getComponentEnabledSetting(ComponentName(info.packageName, info.name))
        }

    private fun target(info: ActivityInfo, label: String) = CompanionMapTarget(
        info.packageName, info.name, info.applicationInfo.uid, label,
    )

    /** Query visibility and actual launch availability are deliberately different facts. */
    fun targets(address: String): Map<String, Any?> {
        val request = intent(address)
        val choices = try {
            packages.queryIntentActivities(request, PackageManager.MATCH_DEFAULT_ONLY)
                .filter { it.activityInfo != null && enabled(it.activityInfo) }
                .map { target(it.activityInfo, it.loadLabel(packages).toString()) }
                .distinctBy { it.packageName to it.componentName }
                .sortedWith(compareBy({ it.label }, { it.packageName }, { it.componentName }))
        } catch (_: RuntimeException) { emptyList() }
        val resolved = try { packages.resolveActivity(request, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo }
            catch (_: RuntimeException) { null }
        val actualDefault = resolved?.let { info -> choices.singleOrNull {
            it.packageName == info.packageName && it.componentName == info.name && it.uid == info.applicationInfo.uid
        } }
        return mapOf("kind" to when { actualDefault != null -> "known"; choices.isNotEmpty() -> "choice"; else -> "unknown" },
            "targets" to choices.map { it.value() }, "defaultTarget" to actualDefault?.value())
    }

    /** Called only inside the ledger's final current-revision gate; there is no await or retry. */
    fun dispatch(activity: Activity, argument: CompanionMapArgument,
                 beforeStart: () -> String? = { null }): CompanionMapObservation {
        val request = intent(argument.address)
        if (argument.targetKind == "choice") {
            require(argument.target == null)
        } else {
            require(argument.targetKind == "selected" || argument.targetKind == "default")
            val selected = requireNotNull(argument.target)
            val component = ComponentName(selected.packageName, selected.componentName)
            val actual = try { packages.getActivityInfo(component, 0) }
                catch (_: PackageManager.NameNotFoundException) { return blocked("map_target_unavailable") }
                catch (_: SecurityException) { return blocked("map_target_unavailable") }
            if (!enabled(actual) || actual.applicationInfo.uid != selected.uid ||
                actual.packageName != selected.packageName || actual.name != selected.componentName)
                return blocked("map_target_changed")
            request.component = component
        }
        val launch = if (argument.targetKind == "choice") Intent.createChooser(request, null) else request
        // Package lookup may involve IPC; recheck the actual foreground after it, next to launch.
        beforeStart()?.let { return blocked(it) }
        return try {
            activity.startActivity(launch)
            if (argument.targetKind == "choice") CompanionMapObservation(
                "chooser_shown", "waiting", "returned", "unknown", "map_target_choice")
            else CompanionMapObservation("handoff_dispatched", "done", "returned", "succeeded")
        } catch (_: ActivityNotFoundException) {
            CompanionMapObservation("not_dispatched", "failed", "failed", "not_performed", "map_handler_unavailable")
        } catch (_: SecurityException) {
            CompanionMapObservation("not_dispatched", "failed", "failed", "not_performed", "map_system_denied")
        } catch (_: RuntimeException) {
            CompanionMapObservation("handoff_unconfirmed", "unknown", "failed", "unknown", "map_handoff_unconfirmed")
        }
    }

    companion object {
        fun blocked(reason: String) = CompanionMapObservation("not_dispatched", "waiting", "blocked", "not_performed", reason)
    }
}
