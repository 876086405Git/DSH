package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayMachineTest {
    private val t0 = 1_000_000L
    private val collapse = OverlayMachine.IDLE_COLLAPSE_MS
    private val dim = OverlayMachine.DIM_AFTER_MS

    private fun push(state: String, active: Boolean = state != "idle" && state != "sleeping", bubble: PetBubble? = null, pack: String? = "whale-girl") =
        PetPush(pack, state, if (state == "working") 1 else 0, bubble, "s1", null, active, "medium")

    private fun bubble(id: String, until: Long) = PetBubble(id, "done", "做完了", "修复登录", "s1", null, until)

    /** Enabled, permitted, pack loaded, app in the background, nothing going on. */
    private fun ready(): OverlayMachine = OverlayMachine().apply {
        enabled = true
        canHost = true
        hasPet = true
        onPush(push("idle"), t0)
        onForeground(false, t0)
    }

    @Test fun hiddenWhileTheAppIsOnScreen() {
        val m = OverlayMachine().apply { enabled = true; canHost = true; hasPet = true }
        m.onPush(push("working"), t0)
        val d = m.decide(t0)
        assertEquals(Visibility.HIDDEN, d.visibility)
        assertEquals("app on screen", d.why)
        assertFalse(d.ownService)
    }

    @Test fun showsInTheBackgroundWhileSomethingIsGoingOn() {
        val m = OverlayMachine().apply { enabled = true; canHost = true; hasPet = true }
        m.onPush(push("working"), t0)
        m.onForeground(false, t0 + 10)
        val d = m.decide(t0 + 20)
        assertEquals(Visibility.SHOWN, d.visibility)
        assertFalse(d.dimmed)
        // Active work has no idle-dimming deadline.
        assertNull(d.wakeAt)
    }

    @Test fun leavingTheAppWithNothingGoingOnShowsNothing() {
        val m = ready()
        assertEquals("nothing going on", m.decide(t0 + 1).why)
    }

    @Test fun collapsesFiveMinutesAfterTheLastActivity() {
        val m = ready()
        m.onPush(push("working"), t0 + 1_000)
        m.onPush(push("attention", active = true), t0 + 60_000)
        m.onPush(push("idle"), t0 + 65_000)
        val d = m.decide(t0 + 70_000)
        assertEquals(Visibility.SHOWN, d.visibility)
        assertEquals(Visibility.SHOWN, m.decide(t0 + 60_000 + collapse - 1).visibility)
        assertEquals(Visibility.HIDDEN, m.decide(t0 + 60_000 + collapse).visibility)
    }

    @Test fun wakeUpIsTheNearestTimer() {
        val m = ready()
        m.onPush(push("attention", active = true), t0)
        m.onPush(push("idle"), t0 + 1)
        // First the dim, ten seconds after it came out…
        assertEquals(t0 + 2 + dim, m.decide(t0 + 2).wakeAt)
        // …then, dimmed, the collapse five minutes after the last activity.
        val d = m.decide(t0 + 2 + dim)
        assertTrue(d.dimmed)
        assertEquals(t0 + collapse, d.wakeAt)
    }

    @Test fun heldAskStopsSchedulingAnExpiredCollapse() {
        val m = ready()
        m.onTouch(t0)
        m.holding = true
        assertEquals(t0 + collapse, m.decide(t0 + collapse - 1).wakeAt)
        val held = m.decide(t0 + collapse)
        assertEquals(Visibility.SHOWN, held.visibility)
        assertFalse(held.dimmed)
        assertNull(held.wakeAt)
        m.holding = false
        assertEquals(Visibility.HIDDEN, m.decide(t0 + collapse + 1).visibility)
    }

    @Test fun alwaysShowNeverCollapses() {
        val m = ready().apply { alwaysShow = true }
        val d = m.decide(t0 + 10 * collapse)
        assertEquals(Visibility.SHOWN, d.visibility)
        m.onForeground(true, t0)
        assertEquals(Visibility.HIDDEN, m.decide(t0).visibility)
    }

    @Test fun screenOffPausesAndKeepsTheProcess() {
        val m = ready()
        m.onPush(push("thinking"), t0)
        m.interactive = false
        val d = m.decide(t0 + 1)
        assertEquals(Visibility.PAUSED, d.visibility)
        assertTrue(d.ownService)
        m.interactive = true
        assertEquals(Visibility.SHOWN, m.decide(t0 + 2).visibility)
    }

    @Test fun ownServiceOnlyWithoutDshService() {
        val m = ready()
        m.onPush(push("working"), t0)
        assertTrue(m.decide(t0).ownService)
        m.dshService = true
        val d = m.decide(t0)
        assertEquals(Visibility.SHOWN, d.visibility)
        assertFalse(d.ownService)
        m.dshService = false
        m.onPush(push("idle"), t0)
        assertFalse(m.decide(t0 + collapse + 1).ownService)
    }

    @Test fun snoozeHidesUntilMidnight() {
        val m = ready()
        m.onPush(push("working"), t0)
        m.snoozedUntil = t0 + 3_600_000
        val d = m.decide(t0 + 5)
        assertEquals("snoozed", d.why)
        assertFalse(d.ownService)
        assertEquals(t0 + 3_600_000, d.wakeAt)
        assertEquals(Visibility.SHOWN, m.decide(t0 + 3_600_000).visibility)
    }

    @Test fun phoneTaskHidesButKeepsTheProcess() {
        val m = ready()
        m.onPush(push("working"), t0)
        m.phoneTask = true
        val d = m.decide(t0)
        assertEquals("phone task", d.why)
        assertTrue(d.ownService)
    }

    @Test fun nothingWithoutPermissionPetOrSwitch() {
        for (setup in listOf<(OverlayMachine) -> Unit>(
            { it.enabled = false },
            { it.canHost = false },
            { it.hasPet = false },
            { it.onPush(push("working", pack = null), t0) },
        )) {
            val m = ready()
            m.onPush(push("working"), t0)
            setup(m)
            val d = m.decide(t0)
            assertEquals(Visibility.HIDDEN, d.visibility)
            assertFalse(d.ownService)
        }
    }

    @Test fun idleDimsTenSecondsAfterTheLastTouchOrCall() {
        val m = ready().apply { alwaysShow = true }
        assertFalse(m.decide(t0).dimmed)
        assertFalse(m.decide(t0 + dim - 1).dimmed)
        // Idle and dimmed, it is still out, whole where it docks at 60 %.
        val d = m.decide(t0 + dim)
        assertTrue(d.dimmed)
        assertEquals(Visibility.SHOWN, d.visibility)
        assertEquals(0.6f, OverlayMachine.DIM_ALPHA, 0f)
        m.onTouch(t0 + dim + 100)
        assertFalse(m.decide(t0 + dim + 200).dimmed)
        // Repeating idle does not extend the deadline; a new call for attention does.
        assertTrue(m.decide(t0 + 3 * dim).dimmed)
        m.onPush(push("idle"), t0 + 3 * dim)
        assertTrue(m.decide(t0 + 3 * dim + 1).dimmed)
        m.onPush(push("attention", active = false), t0 + 3 * dim + 2)
        assertFalse(m.decide(t0 + 3 * dim + 3).dimmed)
        // So does a new bubble.
        assertTrue(m.decide(t0 + 5 * dim).dimmed)
        m.onPush(push("idle", bubble = bubble("b2", t0 + 5 * dim + 4_000)), t0 + 5 * dim)
        assertFalse(m.decide(t0 + 5 * dim + 1).dimmed)
    }

    @Test fun aBubbleKeepsItOutAndLit() {
        val m = ready()
        m.onPush(push("idle", bubble = bubble("b1", t0 + 4_000)), t0)
        val d = m.decide(t0)
        assertEquals(Visibility.SHOWN, d.visibility)
        assertEquals("b1", d.bubble?.id)
        assertEquals(t0 + 4_000, d.wakeAt)
        assertFalse(m.decide(t0 + 3_999).dimmed)
        // Gone at its time.
        assertNull(m.decide(t0 + 4_000).bubble)
    }

    @Test fun bubbleSeenInTheAppIsNotRepeatedOutside() {
        val m = OverlayMachine().apply { enabled = true; canHost = true; hasPet = true }
        m.onPush(push("attention", bubble = bubble("y", t0 + 4_000)), t0)
        m.onForeground(false, t0 + 100)
        m.onPush(push("attention", bubble = bubble("y", t0 + 4_000)), t0 + 200)
        assertNull(m.decide(t0 + 300).bubble)
    }

    @Test fun aTappedBubbleStaysGoneThoughPushedAgain() {
        val m = ready()
        m.onPush(push("idle", bubble = bubble("x", t0 + 8_000)), t0)
        m.bubbles.dismiss()
        m.onPush(push("idle", bubble = bubble("x", t0 + 8_000)), t0 + 10)
        assertNull(m.decide(t0 + 20).bubble)
        // Dart dropping the bubble drops it here too.
        m.onPush(push("idle", bubble = bubble("z", t0 + 8_000)), t0 + 30)
        assertEquals("z", m.decide(t0 + 40).bubble?.id)
        m.onPush(push("idle"), t0 + 50)
        assertNull(m.decide(t0 + 60).bubble)
    }

    @Test fun backInTheAppForgetsWhatHappenedOutside() {
        val m = ready()
        m.onPush(push("attention", active = true, bubble = bubble("b1", t0 + 4_000)), t0)
        assertEquals(Visibility.SHOWN, m.decide(t0).visibility)
        m.onForeground(true, t0 + 1_000)
        m.onPush(push("idle"), t0 + 2_000)
        m.onForeground(false, t0 + 3_000)
        assertEquals(Visibility.HIDDEN, m.decide(t0 + 3_001).visibility)
    }

    @Test fun reappearingStartsLit() {
        val m = ready().apply { alwaysShow = true }
        m.decide(t0)
        assertTrue(m.decide(t0 + dim).dimmed)
        m.onForeground(true, t0 + dim + 1)
        m.decide(t0 + dim + 2)
        m.onForeground(false, t0 + dim + 3)
        assertFalse(m.decide(t0 + dim + 4).dimmed)
    }
}
