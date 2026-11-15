package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The turn's end as Dart reports it (`finishTask`): what it ends, and when it refuses. */
class PhoneTasksFinishTest {
    private var now = 1_000L
    private fun tasks() = PhoneTasks(clock = { now })

    @Test fun theTurnsEndClosesTheRunningTask() {
        val t = tasks()
        val seen = mutableListOf<PhoneTasks.Snapshot>()
        t.addListener { seen += it }
        t.begin()
        t.approve("com.example")
        t.waive()
        assertTrue(t.snapshot().active)
        assertTrue(t.finish())
        val s = t.snapshot()
        assertFalse(s.active)
        assertFalse(s.stopped)
        assertFalse(s.waived)
        // Per-task approvals go with it.
        assertFalse(t.isApproved("com.example"))
        // Listeners hear it (the overlay and the engine notification clear on that).
        assertFalse(seen.last().active)
    }

    @Test fun nothingRunningNothingToFinish() {
        val t = tasks()
        assertFalse(t.finish())
        t.begin()
        t.finish()
        // Twice: the second has nothing left.
        assertFalse(t.finish())
    }

    @Test fun aCallStillInFlightMeansItWasntThisTasksTurn() {
        val t = tasks()
        t.callStarted()
        t.begin()
        assertEquals(1, t.callsInFlight)
        assertFalse(t.finish())
        assertTrue(t.snapshot().active)
        t.callEnded(t.activeOwner())
        assertEquals(0, t.callsInFlight)
        assertTrue(t.finish())
    }

    @Test fun callEndsNeverGoNegative() {
        val t = tasks()
        t.callEnded(t.activeOwner())
        assertEquals(0, t.callsInFlight)
        t.callStarted()
        t.callStarted()
        t.callEnded(t.activeOwner())
        assertEquals(1, t.callsInFlight)
    }

    @Test fun afterAStopTheTurnsEndDropsTheHoldSoTheNextTurnStartsFresh() {
        val t = tasks()
        t.begin()
        t.stop("stopped on the pill")
        assertTrue(t.snapshot().stopped)
        // Within the hold every call is refused…
        assertTrue(t.begin() is PhoneTasks.Begin.Refused)
        // …until the stopped turn has ended.
        assertTrue(t.finish())
        assertFalse(t.snapshot().stopped)
        val next = t.begin()
        assertTrue(next is PhoneTasks.Begin.Go && next.newTask)
    }

    @Test fun anIdleEndedTaskWithoutAStopHasNothingToClose() {
        val t = tasks()
        t.begin()
        now += t.idleMs + 1
        assertTrue(t.expireIdle())
        assertFalse(t.finish())
    }

    @Test fun theStatusCarriesTheTaskIdSoDartSeesANewTask() {
        val t = tasks()
        t.begin()
        val first = t.snapshot().toMap()["id"]
        t.finish()
        t.begin()
        val second = t.snapshot().toMap()["id"]
        assertNotEquals(first, second)
        assertEquals(true, t.snapshot().toMap()["active"])
    }

    @Test fun anOldFinishRequestCannotCloseANewerTask() {
        val t = tasks()
        t.begin()
        val requested = t.snapshot().id
        t.endTask()
        t.begin()
        t.approve("com.example")
        t.waive()
        assertNotEquals(requested, t.snapshot().id)
        assertFalse(t.finish(requested))
        assertTrue(t.snapshot().active)
        assertTrue(t.isApproved("com.example"))
        assertTrue(t.isWaived)
        assertTrue(t.finish(t.snapshot().id))
    }

    @Test fun roundGrantsBelongToOneTurn() {
        val t = tasks()
        val owner = (t.begin() as PhoneTasks.Begin.Go).owner
        assertTrue(t.confirmIfCurrent(owner, grant = PhoneTasks.grantKey("example.app", "first-in-app")))
        assertTrue(t.hasGrant("example.app", "first-in-app"))
        assertFalse(t.hasGrant("example.app", "sensitive:发送"))
        assertFalse(t.hasGrant("other.app", "first-in-app"))
        assertTrue(t.finish())
        assertFalse(t.hasGrant("example.app", "first-in-app")) // 下一轮从零开始。
    }

    @Test fun cancelPendingDropsTheStopHoldSoTheNextTurnStartsFresh() {
        val t = tasks()
        t.begin()
        t.stop("stopped on the pill")
        assertTrue(t.snapshot().stopped)
        assertTrue(t.begin() is PhoneTasks.Begin.Refused)
        t.cancelPending() // Host run end: the stop only covered the turn it interrupted.
        assertFalse(t.isStopped())
        val next = t.begin()
        assertTrue(next is PhoneTasks.Begin.Go && next.newTask)
    }

    @Test fun anOldFinishRequestCannotClearANewerStopHold() {
        val t = tasks()
        t.begin()
        val oldId = t.snapshot().id
        t.endTask()
        t.begin()
        val currentId = t.snapshot().id
        t.stop("user stopped the new task")
        assertFalse(t.finish(oldId))
        assertTrue(t.begin() is PhoneTasks.Begin.Refused)
        assertTrue(t.finish(currentId))
        assertFalse(t.isStopped())
    }
}
