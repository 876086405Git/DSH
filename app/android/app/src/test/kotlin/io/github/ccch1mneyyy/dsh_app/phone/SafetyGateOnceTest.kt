package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.*
import org.junit.Test

class SafetyGateOnceTest {
    private class Fixture(val mode: ConfirmMode = ConfirmMode.ASK) {
        val tasks = PhoneTasks().apply { begin() }
        val owner = tasks.activeOwner()!!
        val requests = mutableListOf<ConfirmRequest>()
        var answer: (ConfirmRequest) -> Decision = { Decision.ALLOW_ONCE }
        var available = true
        private val ui = object : UserGate {
            override fun confirm(request: ConfirmRequest): Decision {
                requests += request
                return answer(request)
            }
            override fun handoff(reason: String, timeoutMs: Long): HandoffResult = error("unexpected handoff")
            override fun status(text: String?) = Unit
        }
        val safety = SafetyGate({ PhonePolicies(confirmMode = mode) }, tasks, { if (available) ui else null })
        fun resolve(): SafetyGate.Result = safety.resolve(
            safety.confirmationOnce("End composition and insert once", "example.app", "Example", "focus-composition"),
            SerialWorker.Scope(), owner)
    }

    @Test fun waivedModesAndApprovedAppStillAskOnce() {
        for (mode in ConfirmMode.entries) {
            val f = Fixture(mode)
            f.tasks.waive()
            f.tasks.approve("example.app")
            val visual = VisualScope.Main(Any(), Any(), 7, "example.app")
            f.tasks.syncVisualScope(f.owner, PhoneScreen.MAIN, visual)
            assertTrue(f.tasks.confirmVisualIfCurrent(f.owner, visual))
            assertTrue(f.tasks.hasVisualGrant(f.owner, visual))
            assertEquals("confirmed", (f.resolve() as SafetyGate.Result.Go).decision)
            assertEquals(1, f.requests.size)
            val request = f.requests.single()
            assertEquals(f.owner, request.owner)
            assertFalse(request.firstInApp)
            assertFalse(request.allowRound)
            assertNull(request.visualScope)
        }
    }

    @Test fun excessiveDecisionsDoNotGrantAppOrTaskAuthority() {
        for (decision in listOf(Decision.ALLOW_APP_FOR_TASK, Decision.ALLOW_VISUAL_FOR_TASK)) {
            val f = Fixture()
            f.answer = { decision }
            assertEquals("denied", (f.resolve() as SafetyGate.Result.No).decision)
            assertEquals(1, f.requests.size)
            assertFalse(f.tasks.isApproved("example.app"))
            assertFalse(f.tasks.isWaived)
            assertTrue(f.tasks.isCurrent(f.owner))
        }
    }

    @Test fun ownerReplacementDuringQuestionRejectsAnAllowOnce() {
        val f = Fixture()
        f.answer = {
            assertTrue(f.tasks.finish())
            f.tasks.begin()
            Decision.ALLOW_ONCE
        }
        assertTrue(f.resolve() is SafetyGate.Result.No)
        assertFalse(f.tasks.isCurrent(f.owner))
        assertFalse(f.tasks.isApproved("example.app"))
        assertFalse(f.tasks.isWaived)
    }

    @Test fun noGateDenialAndStopKeepTheirOwnCopy() {
        val missing = Fixture().apply { available = false }
        val missingResult = missing.resolve() as SafetyGate.Result.No
        assertEquals("refused:no-gate", missingResult.decision)
        assertEquals(PhoneTasks.NO_CONFIRM_MESSAGE + "。", missingResult.message)
        assertTrue(missing.requests.isEmpty())
        for (decision in listOf(Decision.DENY, Decision.STOP, Decision.UNAVAILABLE)) {
            val f = Fixture()
            f.answer = { decision }
            val expected = when (decision) {
                Decision.STOP -> "stopped"
                Decision.UNAVAILABLE -> "refused:no-gate"
                else -> "denied"
            }
            val result = f.resolve() as SafetyGate.Result.No
            assertEquals(expected, result.decision)
            // 取消 / 停止本轮 / 弹不出确认是三件不同的事，文案不能混用。
            val message = when (decision) {
                Decision.DENY -> PhoneTasks.CANCELLED_MESSAGE
                Decision.STOP -> PhoneTasks.STOPPED_MESSAGE
                else -> PhoneTasks.NO_CONFIRM_MESSAGE
            }
            assertEquals(message + "。", result.message)
            assertFalse(f.tasks.isApproved("example.app"))
            assertFalse(f.tasks.isWaived)
            if (decision == Decision.STOP) assertFalse(f.tasks.isCurrent(f.owner))
        }
    }

    @Test fun ordinaryConfirmationRetainsWaiverAndRoundGrantBehavior() {
        val waived = Fixture(ConfirmMode.ALWAYS)
        assertSame(SafetyGate.Verdict.Allow,
            waived.safety.confirmation("ordinary", "example.app", null, "ordinary"))
        val f = Fixture()
        f.answer = { Decision.ALLOW_APP_FOR_TASK }
        val result = f.safety.resolve(f.safety.confirmation("ordinary", "example.app", null, "ordinary"),
            SerialWorker.Scope(), f.owner)
        assertEquals("confirmed-app", (result as SafetyGate.Result.Go).decision)
        assertTrue(f.tasks.isApproved("example.app"))
        assertTrue(f.tasks.hasGrant("example.app", "ordinary"))
        assertFalse(f.tasks.isWaived) // 每次都询问模式下，本轮允许不动旧的任务级豁免。
    }

    @Test fun taskModeRoundGrantStillWaivesTheRestOfTheTurn() {
        val f = Fixture(ConfirmMode.TASK)
        f.answer = { Decision.ALLOW_APP_FOR_TASK }
        assertEquals("confirmed-app", (f.safety.resolve(
            f.safety.confirmation("ordinary", "example.app", null, "ordinary"),
            SerialWorker.Scope(), f.owner) as SafetyGate.Result.Go).decision)
        assertTrue(f.tasks.isWaived)
        // 旧「本任务免确认」模式下，本轮允许仍然免掉本轮后续的普通确认。
        assertSame(SafetyGate.Verdict.Allow, f.safety.confirmation("next", "other.app", null, "ordinary"))
    }
}
