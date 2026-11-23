package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.PhoneAction
import io.github.ccch1mneyyy.dsh_app.phone.PhoneScreen
import io.github.ccch1mneyyy.dsh_app.phone.PhoneTasks
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PhoneSkillServiceTest {
    @get:Rule val folder = TemporaryFolder()
    private val trace = PhoneTaskTrace()
    private val runs = PhoneSkillRuns(trace)
    private val key = PhoneSkillRuns.Key("chat", "turn")
    private val owner = PhoneTasks.Owner(7, 1, true)
    private val traceApp = "example.notes"
    private val document = PhoneSkillDocument("phone-notes", "Notes", "Read notes", "When checking notes",
        listOf(traceApp), PhoneSkillDocument.englishHeadings.mapValues { "Check the app." }, true)
    private var learn = true
    private val events = mutableListOf<Map<String, Any?>>()
    private val service = PhoneSkillService(runs, { learn }, { learn = it }, { true }, { "Draft a procedure" }, events::add)
    private fun store(): PhoneSkillStore {
        val root = File(folder.root, "rootfs")
        File(root, "root/.dsh").mkdirs()
        return PhoneSkillStore(root, File(folder.root, "native"), PhoneSkillValidation::clean, PhoneSkillValidation::redactLegacy)
    }

    private fun action(app: String) {
        val ticket = trace.beginAction(owner, PhoneAction.Tap("s1", 1), null, app)
        trace.finish(ticket, true, false, true)
    }

    private fun start() = runs.start(owner, key.session, key.run)!!
    private fun finish(epoch: Long, completion: String = "completed"): PhoneSkillRuns.Drained {
        assertTrue(runs.complete(owner, epoch, completion))
        return runs.awaitFinish(key, epoch)!!
    }
    private fun install(store: PhoneSkillStore): PhoneSkillSaved =
        store.accept(store.putDraft(document, PhoneSkillOrigin(key.session, owner.taskId)).id)
    private fun follow(s: PhoneSkillStore, skill: PhoneSkillSaved) {
        service.engine(mapOf("op" to "read", "runLifecycle" to 1L, "sessionId" to key.session, "runId" to key.run,
            "reads" to listOf(mapOf("name" to skill.document.name, "fingerprint" to skill.readFingerprint))), s, runs.epoch(), null)
    }

    @Test fun earlierReadThenMatchingActionPromotesExactlyOnceEvenWithLearningOff() {
        val s = store()
        val skill = install(s)
        service.ui("skills.setLearn", mapOf("on" to false), s)
        follow(s, skill)
        val epoch = start()
        action(traceApp)
        val drained = finish(epoch)
        service.engine(mapOf("op" to "finish", "draft" to true, "observationComplete" to true), s, epoch, drained)
        val active = s.get(document.name)
        assertEquals("active", active.status.state)
        assertNotEquals(skill.fingerprint, active.fingerprint)
        assertEquals(skill.readFingerprint, active.readFingerprint)
        assertEquals("promoted", events.single()["change"])
        assertEquals(PhoneSkillOrigin(key.session, owner.taskId).toMap(), events.single()["from"])
        assertNull(runs.awaitFinish(key, epoch))
        assertTrue(s.list().drafts.isEmpty())
    }

    @Test fun incompleteReadObservationNeitherScoresNorDrafts() {
        val s = store()
        val skill = install(s)
        follow(s, skill)
        val epoch = start()
        repeat(3) { action(traceApp) }
        val reply = service.engine(mapOf("op" to "finish", "draft" to true, "observationComplete" to false),
            s, epoch, finish(epoch))
        assertTrue(reply.isEmpty())
        assertEquals(0L, s.get(document.name).status.uses)
        assertTrue(s.list().drafts.isEmpty())
        assertTrue(events.isEmpty())
    }

    @Test fun readingAfterAnActionAndOnlyOpeningTheAppDoesNotAttributeItsResult() {
        val s = store()
        val epoch = start()
        action(traceApp)
        follow(s, install(s))
        val open = trace.beginOpen(owner, PhoneScreen.MAIN, traceApp)
        trace.finish(open, true, false, true)
        action("example.other")
        assertNull(finish(epoch).followed)
    }

    @Test fun ambiguousReadsAndUserInterventionHaveSeparateEffects() {
        val epoch = start()
        runs.read(key, listOf(document, document.copy(name = "phone-other")), epoch)
        action(traceApp)
        trace.userIntervened(owner)
        val drained = finish(epoch)
        assertTrue(drained.ambiguous)
        assertNull(drained.followed)
        assertEquals("miss", drained.outcome)
        assertFalse(drained.trace.canLearn)
    }

    @Test fun finishWaitsForDrainAndRetirementReleasesOrphanedWaiters() {
        val epoch = start()
        val started = CountDownLatch(1)
        val future = CompletableFuture.supplyAsync { started.countDown(); runs.awaitFinish(key, epoch) }
        assertTrue(started.await(2, TimeUnit.SECONDS))
        assertFalse(future.isDone)
        action(traceApp)
        trace.markIncomplete(owner, PhoneTaskTrace.Gap.UNCERTAIN_RESULT)
        runs.complete(owner, epoch, "completed")
        assertEquals("void", future.get(2, TimeUnit.SECONDS)!!.outcome)

        start()
        val retired = CompletableFuture.supplyAsync { runs.awaitFinish(key, epoch) }
        runs.retire()
        try { assertNull(retired.get(2, TimeUnit.SECONDS)) }
        catch (e: java.util.concurrent.ExecutionException) { assertTrue(e.cause is PhoneSkillProblem) }
    }

    @Test fun threeActionsProduceOneSingleUseDraftTicketAndAnEditableCard() {
        val s = store()
        val epoch = start()
        repeat(3) { action(traceApp) }
        val reply = service.engine(mapOf("op" to "finish", "draft" to true, "observationComplete" to true), s, epoch, finish(epoch))
        val ticket = reply["ticket"] as String
        assertTrue((reply["prompt"] as String).contains(traceApp))
        val response = document.render("trial", "learned", null).replace("state: trial\ndisable-model-invocation: true\nuser-invocable: false\n", "")
        service.engine(mapOf("op" to "offer", "ticket" to ticket, "response" to response), s, epoch, null)
        val draft = s.list().drafts.single()
        assertEquals("skillDraft", events.single()["type"])
        assertTrue(s.list().skills.isEmpty())
        assertEquals(document.name, service.ui("skills.accept", mapOf("draftId" to draft.id), s)["name"])
        try {
            service.engine(mapOf("op" to "offer", "ticket" to ticket, "response" to response), s, epoch, null)
            fail("Ticket used twice")
        } catch (e: PhoneSkillProblem) { assertEquals("changed", e.code) }
    }
}
