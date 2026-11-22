package io.github.ccch1mneyyy.dsh_app.pet

/** Which window type hosts the pet. */
enum class OverlayHost { ACCESSIBILITY, APPLICATION, NONE }

/**
 * What the settings show about permission (`permission` in the status map):
 *
 * - `accessibility`: the service is on and needs no new application-overlay permission grant;
 * - `granted`: the overlay permission works (or nothing has failed yet with it reported on);
 * - `blocked`: the system reports the permission but adding the window failed — a vendor's own
 *   floating-window switch (vivo, some others) that `canDrawOverlays` doesn't see;
 * - `denied`: no permission, and no window could be added.
 */
enum class OverlayPermission(val wire: String) {
    ACCESSIBILITY("accessibility"),
    GRANTED("granted"),
    BLOCKED("blocked"),
    DENIED("denied"),
}

/**
 * The last attempt to add a TYPE_APPLICATION_OVERLAY window: null when none was made since the
 * permission last changed. The attempt is what counts — `Settings.canDrawOverlays` is wrong on
 * some vendor builds in both directions.
 */
enum class AddResult { OK, FAILED }

object OverlayAccess {
    fun permission(
        a11yConnected: Boolean, canDraw: Boolean, lastAdd: AddResult?, a11yFailed: Boolean = false,
    ): OverlayPermission = when {
        a11yFailed && !canDraw -> OverlayPermission.DENIED
        a11yConnected -> OverlayPermission.ACCESSIBILITY
        lastAdd == AddResult.OK -> OverlayPermission.GRANTED
        lastAdd == AddResult.FAILED -> if (canDraw) OverlayPermission.BLOCKED else OverlayPermission.DENIED
        canDraw -> OverlayPermission.GRANTED
        else -> OverlayPermission.DENIED
    }

    /**
     * The window type to try. Without the accessibility service an application overlay is tried
     * until an attempt fails — also when `canDrawOverlays` says no (a vendor build that lies).
     * During an accessibility failure's cooldown, fallback requires explicit overlay permission.
     */
    fun host(a11yConnected: Boolean, lastAdd: AddResult?, a11yFailed: Boolean = false, canDraw: () -> Boolean = { false }): OverlayHost = when {
        a11yConnected && !a11yFailed -> OverlayHost.ACCESSIBILITY
        // A failed accessibility add does not grant permission to use an application overlay.
        a11yFailed && !canDraw() -> OverlayHost.NONE
        lastAdd == AddResult.FAILED -> OverlayHost.NONE
        else -> OverlayHost.APPLICATION
    }

    /**
     * Whether a failed attempt may be forgotten and the window tried again: when the reported
     * permission changed, or — while the system claims it is granted, so a vendor switch may have
     * been flipped meanwhile — after [RETRY_MS]. A plain denial waits for the permission to change.
     */
    fun retry(lastAdd: AddResult?, failedAt: Long, now: Long, canDraw: Boolean, canDrawChanged: Boolean): Boolean =
        lastAdd != AddResult.FAILED || canDrawChanged || (canDraw && now - failedAt >= RETRY_MS)

    const val RETRY_MS = 60_000L
}

/** Failed accessibility windows wait even when removal callbacks immediately evaluate again. */
internal class AccessibilityOverlayRetry {
    private var connection: Any? = null
    private var failedAt: Long? = null

    fun failed(service: Any, now: Long) {
        connection = service
        failedAt = now
    }

    fun remaining(service: Any?, now: Long): Long? {
        if (connection !== service) {
            connection = service
            failedAt = null
        }
        return failedAt?.let { (OverlayAccess.RETRY_MS - (now - it)).takeIf { delay -> delay > 0 } }
    }
}
