package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.PhoneTaskSessions
import io.github.ccch1mneyyy.dsh_app.phone.PhoneTasks
import java.util.UUID
import java.util.concurrent.CompletableFuture

/** Run-bound memory only. Registry callbacks never perform file IO or wait for the host. */
internal class PhoneSkillRuns(private val trace: PhoneTaskTrace) {
    data class Key(val session: String, val run: String)
    data class Read(val document: PhoneSkillDocument, val cursor: Int)
    data class Drained(val from: PhoneSkillOrigin, val trace: PhoneTaskTrace.Snapshot,
        val followed: PhoneSkillDocument?, val ambiguous: Boolean, val outcome: String)
    private class Run {
        var owner: PhoneTasks.Owner? = null
        val reads = mutableListOf<Read>()
        val drained = CompletableFuture<Drained?>()
        var claimed = false
    }
    data class Offer(val from: PhoneSkillOrigin, val request: PhoneSkillDrafter.Request)
    private val runs = mutableMapOf<Key, Run>()
    private val offers = mutableMapOf<String, Offer>()
    private var generation = 0L

    @Synchronized fun epoch() = generation

    @Synchronized fun start(owner: PhoneTasks.Owner, session: String?, runId: String?): Long? {
        if (session == null || runId == null) return null
        val key = Key(session, runId)
        if (key !in runs && runs.size >= PhoneTaskSessions.MAX_RUNS_PER_LAUNCH) return null
        val run = reserve(key)
        if (run.owner != null) return null
        trace.start(owner)
        run.owner = owner
        return generation
    }

    private fun reserve(key: Key): Run = runs[key] ?: run {
        if (runs.size >= PhoneTaskSessions.MAX_RUNS_PER_LAUNCH) invalidSkill("Too many unresolved skill runs.")
        Run().also { runs[key] = it }
    }

    @Synchronized fun read(key: Key, documents: List<PhoneSkillDocument>, expectedEpoch: Long) {
        if (generation != expectedEpoch) changedSkill()
        if (documents.isEmpty()) return
        val run = reserve(key)
        if (run.claimed || run.drained.isDone) return
        val cursor = run.owner?.let { trace.snapshot(it)?.steps?.size } ?: 0
        for (document in documents) {
            if (run.reads.none { it.document == document }) run.reads += Read(document, cursor)
        }
    }

    @Synchronized fun complete(owner: PhoneTasks.Owner, epoch: Long, completion: String): Boolean {
        if (epoch != generation) return false
        val (key, run) = runs.entries.firstOrNull { it.value.owner == owner } ?: return false
        trace.complete(owner, completion == "completed")
        val snapshot = trace.snapshot(owner)
        trace.discard(PhoneTaskTrace.key(owner))
        val result = snapshot?.let {
            val used = run.reads.filter { read ->
                it.steps.drop(read.cursor).any { step ->
                    step.action != PhoneTaskTrace.Action.OPEN_APP && step.receipt == PhoneTaskTrace.Receipt.RETURNED_OK &&
                        step.packageName in read.document.apps
                }
            }
            val outcome = when {
                completion == "user-stop" || it.userIntervened -> "miss"
                completion == "completed" && !it.confirmationUnresolved && it.gap == null &&
                    it.steps.lastOrNull()?.receipt == PhoneTaskTrace.Receipt.RETURNED_OK -> "ok"
                else -> "void"
            }
            Drained(PhoneSkillOrigin(key.session, owner.taskId), it, used.singleOrNull()?.document, used.size > 1, outcome)
        }
        run.drained.complete(result)
        return true
    }

    fun awaitFinish(key: Key, expectedEpoch: Long): Drained? {
        val run = synchronized(this) {
            if (generation != expectedEpoch) changedSkill()
            val entry = runs[key] ?: return null
            if (entry.claimed) return null
            entry.claimed = true
            if (entry.owner == null) entry.drained.complete(null)
            entry
        }
        try { return run.drained.get() }
        finally { synchronized(this) { runs.remove(key, run) } }
    }

    @Synchronized fun ticket(offer: Offer, expectedEpoch: Long): String {
        if (generation != expectedEpoch) changedSkill()
        if (offers.size >= PhoneTaskSessions.MAX_RUNS_PER_LAUNCH) invalidSkill("Too many outstanding draft requests.")
        return UUID.randomUUID().toString().also { offers[it] = offer }
    }

    @Synchronized fun take(id: String, expectedEpoch: Long): Offer? {
        if (generation != expectedEpoch) changedSkill()
        return offers.remove(id)
    }

    @Synchronized fun forgetOffers() = offers.clear()

    @Synchronized fun retire() {
        generation++
        for (run in runs.values) run.drained.complete(null)
        runs.clear()
        offers.clear()
        trace.clear()
    }
}
