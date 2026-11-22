package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayAccessTest {
    @Test fun accessibilityServiceNeedsNothingElse() {
        assertEquals(OverlayPermission.ACCESSIBILITY, OverlayAccess.permission(true, false, null))
        assertEquals(OverlayPermission.ACCESSIBILITY, OverlayAccess.permission(true, false, AddResult.FAILED))
        assertEquals(OverlayHost.ACCESSIBILITY, OverlayAccess.host(true, AddResult.FAILED))
    }

    @Test fun grantedWhenTheWindowWentIn() {
        assertEquals(OverlayPermission.GRANTED, OverlayAccess.permission(false, true, AddResult.OK))
        assertEquals(OverlayPermission.GRANTED, OverlayAccess.permission(false, true, null))
        // canDrawOverlays says no, but the window went in (a vendor build that lies): it works.
        assertEquals(OverlayPermission.GRANTED, OverlayAccess.permission(false, false, AddResult.OK))
        assertEquals(OverlayHost.APPLICATION, OverlayAccess.host(false, AddResult.OK))
    }

    @Test fun vendorSwitchOffIsBlockedNotGranted() {
        // vivo: canDrawOverlays true, addView refused.
        assertEquals(OverlayPermission.BLOCKED, OverlayAccess.permission(false, true, AddResult.FAILED))
        assertEquals(OverlayHost.NONE, OverlayAccess.host(false, AddResult.FAILED))
    }

    @Test fun deniedWithoutPermission() {
        assertEquals(OverlayPermission.DENIED, OverlayAccess.permission(false, false, null))
        assertEquals(OverlayPermission.DENIED, OverlayAccess.permission(false, false, AddResult.FAILED))
        // Untried: still worth one attempt.
        assertEquals(OverlayHost.APPLICATION, OverlayAccess.host(false, null))
    }

    @Test fun onlyAnAccessibilityFailureChecksSystemOverlayPermissionForTheHost() {
        var checks = 0
        val permission = { checks++; false }
        assertEquals(OverlayHost.ACCESSIBILITY, OverlayAccess.host(true, null, canDraw = permission))
        assertEquals(OverlayHost.APPLICATION, OverlayAccess.host(false, null, canDraw = permission))
        assertEquals(0, checks)
        assertEquals(OverlayHost.NONE, OverlayAccess.host(true, null, a11yFailed = true, canDraw = permission))
        assertEquals(1, checks)
    }

    @Test fun retriesAfterAFailure() {
        val failedAt = 1_000L
        // Nothing failed: nothing to forget.
        assertTrue(OverlayAccess.retry(null, 0, 5, canDraw = false, canDrawChanged = false))
        // The person flipped the system switch.
        assertTrue(OverlayAccess.retry(AddResult.FAILED, failedAt, failedAt + 1, canDraw = true, canDrawChanged = true))
        // Reported granted but refused: try again after a while (the vendor switch may have changed).
        assertFalse(OverlayAccess.retry(AddResult.FAILED, failedAt, failedAt + OverlayAccess.RETRY_MS - 1, canDraw = true, canDrawChanged = false))
        assertTrue(OverlayAccess.retry(AddResult.FAILED, failedAt, failedAt + OverlayAccess.RETRY_MS, canDraw = true, canDrawChanged = false))
        // Plainly denied: wait for the permission to change, however long.
        assertFalse(OverlayAccess.retry(AddResult.FAILED, failedAt, failedAt + 10 * OverlayAccess.RETRY_MS, canDraw = false, canDrawChanged = false))
    }

    @Test fun wireNamesMatchDart() {
        assertEquals(listOf("accessibility", "granted", "blocked", "denied"), OverlayPermission.values().map { it.wire })
    }

    @Test fun accessibilityFailureOnlyFallsBackWithExplicitPermission() {
        assertEquals(OverlayHost.NONE, OverlayAccess.host(true, AddResult.OK, a11yFailed = true, canDraw = { false }))
        assertEquals(OverlayHost.APPLICATION, OverlayAccess.host(true, null, a11yFailed = true, canDraw = { true }))
        assertEquals(OverlayHost.NONE, OverlayAccess.host(true, AddResult.FAILED, a11yFailed = true, canDraw = { true }))
        assertEquals(OverlayHost.ACCESSIBILITY, OverlayAccess.host(true, AddResult.FAILED, a11yFailed = false, canDraw = { true }))
    }

    @Test fun failedAccessibilityPermissionRecoversWithTheExistingCooldown() {
        val retry = AccessibilityOverlayRetry()
        val connected = Any()
        val failedAt = 1_000L
        fun permission(service: Any = connected, canDraw: Boolean = false, now: Long = failedAt + 1) =
            OverlayAccess.permission(true, canDraw, AddResult.OK, a11yFailed = retry.remaining(service, now) != null)

        assertEquals(OverlayPermission.ACCESSIBILITY, permission())
        retry.failed(connected, failedAt)
        // Even a previous application-overlay success cannot authorize this fallback.
        assertEquals(OverlayPermission.DENIED, permission())
        assertEquals(OverlayPermission.ACCESSIBILITY, permission(canDraw = true))
        assertEquals(OverlayPermission.ACCESSIBILITY, permission(now = failedAt + OverlayAccess.RETRY_MS))
        retry.failed(connected, failedAt + OverlayAccess.RETRY_MS)
        assertEquals(OverlayPermission.ACCESSIBILITY, permission(service = Any(), now = failedAt + OverlayAccess.RETRY_MS + 1))
    }

    @Test fun failedAccessibilityAddCannotSpinThroughRemovalCallbacks() {
        val retry = AccessibilityOverlayRetry()
        val service = Any()
        val failedAt = 1_000L
        retry.failed(service, failedAt)
        repeat(500) { callback ->
            assertTrue(retry.remaining(service, failedAt + callback) != null)
        }
        assertEquals(1L, retry.remaining(service, failedAt + OverlayAccess.RETRY_MS - 1))
        assertEquals(null, retry.remaining(service, failedAt + OverlayAccess.RETRY_MS))
        retry.failed(service, failedAt + OverlayAccess.RETRY_MS)
        assertEquals(OverlayAccess.RETRY_MS, retry.remaining(service, failedAt + OverlayAccess.RETRY_MS))
    }

    @Test fun reconnectedAccessibilityServiceDoesNotInheritOldTokenFailure() {
        val retry = AccessibilityOverlayRetry()
        val oldService = Any()
        retry.failed(oldService, 1_000L)
        assertEquals(null, retry.remaining(Any(), 1_001L))
        retry.failed(oldService, 1_002L)
        assertEquals(null, retry.remaining(null, 1_003L))
        assertEquals(null, retry.remaining(oldService, 1_004L))
    }
}
