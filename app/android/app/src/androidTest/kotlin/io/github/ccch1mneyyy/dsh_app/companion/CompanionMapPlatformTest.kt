package io.github.ccch1mneyyy.dsh_app.companion

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.test.InstrumentationTestCase
import io.github.ccch1mneyyy.dsh_app.MainActivity
import java.net.URLDecoder

/** Real Android Intent/PM metadata, controlled Activity.startActivity boundary. No map app is launched. */
@Suppress("DEPRECATION")
class CompanionMapPlatformTest : InstrumentationTestCase() {
    private val context get() = instrumentation.targetContext
    private val address = "上海 A&B +?#/东门"
    private fun selected(uidOffset: Int = 0): CompanionMapArgument {
        // A real exported activity is used only as a controlled target, not claimed to be a geo handler.
        val info = context.packageManager.getActivityInfo(ComponentName(context, MainActivity::class.java), 0)
        return CompanionMapArgument(address, "selected", CompanionMapTarget(info.packageName, info.name,
            info.applicationInfo.uid + uidOffset, info.loadLabel(context.packageManager).toString()))
    }

    fun testTheWholeOriginalAddressIsOneEncodedGeoValue() = runTestOnUiThread {
        val uri = CompanionMapAddress.uri(address)
        assertEquals("geo:0,0?q=%E4%B8%8A%E6%B5%B7%20A%26B%20%2B%3F%23%2F%E4%B8%9C%E9%97%A8", uri)
        assertEquals(address, URLDecoder.decode(uri.removePrefix("geo:0,0?q="), "UTF-8"))
    }

    fun testSelectedIdentityGetsOneViewIntentAndOnlyAHandoffReceipt() = runTestOnUiThread {
        val activity = CapturingActivity()
        val argument = selected()
        val observed = CompanionMapPlatform(context).dispatch(activity, argument)
        assertEquals("handoff_dispatched", observed.result)
        assertEquals("done", observed.state); assertEquals("succeeded", observed.outcome)
        val intent = activity.calls.single()
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals(CompanionMapAddress.uri(address), intent.dataString)
        assertEquals(ComponentName(argument.target!!.packageName, argument.target.componentName), intent.component)
        assertEquals(0, intent.flags); assertNull(intent.extras)
    }

    fun testChooserIsOnlyWaitingAndCarriesTheSameFixedViewRequest() = runTestOnUiThread {
        val activity = CapturingActivity()
        val observed = CompanionMapPlatform(context).dispatch(activity, CompanionMapArgument(address, "choice", null))
        assertEquals("chooser_shown", observed.result)
        assertEquals("waiting", observed.state); assertEquals("unknown", observed.outcome)
        val intent = activity.calls.single()
        assertEquals(Intent.ACTION_CHOOSER, intent.action)
        val request = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        assertEquals(Intent.ACTION_VIEW, request.action)
        assertEquals(CompanionMapAddress.uri(address), request.dataString)
        assertNull(request.component); assertNull(request.extras)
    }

    fun testPackageVisibilityFailureIsUnknownAndStillPermitsAnExplicitChooser() = runTestOnUiThread {
        val hidden = object : ContextWrapper(context) {
            override fun getPackageManager(): PackageManager = throw IllegalStateException("controlled package query unavailable")
        }
        val platform = CompanionMapPlatform(hidden)
        val targets = platform.targets(address)
        assertEquals("unknown", targets["kind"])
        assertEquals(emptyList<Any>(), targets["targets"])
        val activity = CapturingActivity()
        assertEquals("chooser_shown", platform.dispatch(activity, CompanionMapArgument(address, "choice", null)).result)
        assertEquals(1, activity.calls.size)
    }

    fun testTheFinalScopeCheckAfterTargetLookupPreventsTheSystemCall() = runTestOnUiThread {
        val activity = CapturingActivity()
        var checks = 0
        val observed = CompanionMapPlatform(context).dispatch(activity, selected()) {
            checks++; "map_scope_closed"
        }
        assertEquals(1, checks); assertTrue(activity.calls.isEmpty())
        assertEquals("waiting", observed.state); assertEquals("not_performed", observed.outcome)
    }

    fun testChangedPackageUidCannotReceiveTheOldAgreement() = runTestOnUiThread {
        val activity = CapturingActivity()
        val observed = CompanionMapPlatform(context).dispatch(activity, selected(uidOffset = 1))
        assertTrue(activity.calls.isEmpty())
        assertEquals("map_target_changed", observed.reason); assertEquals("not_performed", observed.outcome)
    }

    fun testKnownSystemRejectionAndUnconfirmedFailureRemainDifferent() = runTestOnUiThread {
        val cases = listOf(
            ActivityNotFoundException("controlled missing handler") to "not_performed",
            SecurityException("controlled system refusal") to "not_performed",
            IllegalStateException("controlled unconfirmed return") to "unknown",
        )
        for ((failure, expected) in cases) {
            val activity = CapturingActivity(failure)
            val observed = CompanionMapPlatform(context).dispatch(activity, CompanionMapArgument(address, "choice", null))
            assertEquals(1, activity.calls.size)
            assertEquals(expected, observed.outcome)
            assertEquals(if (expected == "unknown") "unknown" else "failed", observed.state)
        }
    }

    private class CapturingActivity(private val failure: RuntimeException? = null) : Activity() {
        val calls = mutableListOf<Intent>()
        override fun startActivity(intent: Intent) {
            calls.add(intent)
            failure?.let { throw it }
        }
    }
}
