package io.github.ccch1mneyyy.dsh_app.phone.skills

/** Native channel projections and the smaller, engine-only proposal/observation protocol. */
internal class PhoneSkillService(
    private val runs: PhoneSkillRuns,
    private val learn: () -> Boolean,
    private val setLearn: (Boolean) -> Unit,
    private val english: () -> Boolean,
    private val template: () -> String,
    private val event: (Map<String, Any?>) -> Unit,
) {
    fun ui(method: String, args: Map<*, *>, store: PhoneSkillStore): Map<String, Any?> = when (method) {
        "skills.list" -> store.list().toMap(learn())
        "skills.get" -> store.get(args.string("name")).toMap()
        "skills.setLearn" -> {
            val on = args["on"] as? Boolean ?: invalidSkill("on")
            setLearn(on)
            if (!on) runs.forgetOffers()
            mapOf("learn" to on)
        }
        "skills.accept" -> store.accept(args.string("draftId"), args.sections("edited")).toMap()
        "skills.discard" -> { store.discard(args.string("draftId")); emptyMap() }
        "skills.save" -> store.save(args.string("name"), args.optionalString("display"),
            args.optionalString("description"), args.optionalString("whenToUse"), args.sections("sections")).toMap()
        "skills.setEnabled" -> store.setEnabled(args.string("name"), args["on"] as? Boolean ?: invalidSkill("on")).toMap()
        "skills.restore" -> store.restore(args.string("name")).toMap()
        "skills.delete" -> { store.delete(args.string("name")); emptyMap() }
        else -> invalidSkill("Unknown skill method.")
    }

    fun runKey(args: Map<*, *>): PhoneSkillRuns.Key {
        if (args["runLifecycle"] != 1L) invalidSkill("runLifecycle")
        fun id(field: String): String = args.string(field).takeIf { it.length in 1..256 && it.none(Char::isISOControl) }
            ?: invalidSkill(field)
        return PhoneSkillRuns.Key(id("sessionId"), id("runId"))
    }

    fun engine(args: Map<*, *>, store: PhoneSkillStore, epoch: Long, drained: PhoneSkillRuns.Drained?): Map<String, Any?> {
        if (runs.epoch() != epoch) changedSkill()
        return when (args["op"]) {
            "catalog" -> {
                val skills = store.list().skills
                mapOf("learn" to learn(), "skills" to skills.map(::row),
                    "quarantined" to store.quarantined(skills.map { it.document.name }.toSet()))
            }
            "get" -> store.get(args.string("name")).let { row(it) + ("body" to it.body) }
            "read" -> {
                val key = runKey(args)
                val reads = args["reads"] as? List<*> ?: invalidSkill("reads")
                val docs = reads.map { value ->
                    val ref = value as? Map<*, *> ?: invalidSkill("reads")
                    val skill = store.get(ref.string("name"))
                    if (skill.status.state == "suspended" || skill.readFingerprint != ref.string("fingerprint")) changedSkill()
                    skill.document
                }
                runs.read(key, docs, epoch)
                emptyMap()
            }
            "finish" -> {
                if (args["observationComplete"] != true) return emptyMap()
                val completed = drained ?: return emptyMap()
                val followed = completed.followed
                if (followed != null) {
                    val result = store.record(followed.name, completed.outcome, followed)
                    result.change?.let { change -> event(mapOf("type" to "skillOutcome", "name" to followed.name,
                        "display" to followed.display, "state" to result.skill.status.state, "change" to change,
                        "from" to completed.from.toMap())) }
                    return emptyMap()
                }
                if (completed.ambiguous || completed.outcome != "ok" || args["draft"] != true || !learn() ||
                    !completed.trace.canLearn) return emptyMap()
                val listing = store.list()
                val targets = (listing.drafts.map { PhoneSkillDrafter.Target(it.document, it.targetSnapshot()) } +
                    listing.skills.filter { it.status.state != "suspended" }.map {
                        PhoneSkillDrafter.Target(it.document, it.targetSnapshot())
                    }).distinctBy { it.document.name }
                val request = PhoneSkillDrafter.prepare(template(), english(), completed.trace, targets) ?: return emptyMap()
                mapOf("ticket" to runs.ticket(PhoneSkillRuns.Offer(completed.from, request), epoch), "prompt" to request.prompt)
            }
            "offer" -> {
                val offer = runs.take(args.string("ticket"), epoch) ?: changedSkill()
                val response = args["response"] ?: return emptyMap()
                if (!learn()) return emptyMap()
                val proposal = offer.request.parse(response as? String ?: invalidSkill("response")) ?: return emptyMap()
                val draft = store.putDraft(proposal.document, offer.from, proposal.target)
                event(mapOf("type" to "skillDraft", "draft" to draft.toMap()))
                emptyMap()
            }
            else -> invalidSkill("Unknown skill operation.")
        }
    }

    private fun row(skill: PhoneSkillSaved) = mapOf(
        "name" to skill.document.name, "display" to skill.document.display, "description" to skill.document.description,
        "whenToUse" to skill.document.whenToUse, "apps" to skill.document.apps, "state" to skill.status.state,
        "source" to skill.source, "fingerprint" to skill.fingerprint, "readFingerprint" to skill.readFingerprint,
        "updatedAt" to skill.updatedAt,
    )
    private fun Map<*, *>.string(key: String) = this[key] as? String ?: invalidSkill(key)
    private fun Map<*, *>.optionalString(key: String): String? = if (containsKey(key)) string(key) else null
    private fun Map<*, *>.sections(key: String): Map<String, String>? {
        if (!containsKey(key)) return null
        val fields = this[key] as? Map<*, *> ?: invalidSkill(key)
        return fields.entries.associate {
            (it.key as? String ?: invalidSkill(key)) to (it.value as? String ?: invalidSkill(key))
        }
    }
}
