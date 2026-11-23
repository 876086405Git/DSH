package io.github.ccch1mneyyy.dsh_app.phone.skills

internal data class PhoneSkillStatus(
    val state: String = "trial", val uses: Long = 0, val recent: List<String> = emptyList(),
    val proven: Boolean = false, val scored: List<String> = emptyList(), val lastAccepted: String? = null,
    val suspensionReason: String? = null,
) {
    fun record(outcome: String): PhoneSkillStatus {
        if (outcome !in listOf("ok", "miss", "void")) invalidSkill("Invalid outcome.")
        if (state == "suspended") return this
        val history = (recent + outcome).takeLast(5)
        val window = if (outcome == "void") scored else (scored + outcome).takeLast(3)
        val next = when {
            outcome == "miss" && window.count { it == "miss" } >= 2 -> "suspended"
            outcome == "ok" -> "active"
            else -> state
        }
        return copy(state = next, uses = uses + 1, recent = history, proven = proven || outcome == "ok",
            scored = window, suspensionReason = if (next == "suspended") "misses" else null)
    }

    fun enable(on: Boolean): PhoneSkillStatus = when {
        on && state == "suspended" -> copy(state = if (proven) "active" else "trial", scored = emptyList(),
            suspensionReason = null)
        !on && state != "suspended" -> copy(state = "suspended", suspensionReason = "manual")
        else -> this
    }

    fun toMap() = mapOf("state" to state, "uses" to uses, "recent" to recent, "proven" to proven,
        "scored" to scored, "lastAccepted" to lastAccepted, "suspensionReason" to suspensionReason)
}

internal data class PhoneSkillSaved(
    val document: PhoneSkillDocument, val source: String, val from: PhoneSkillOrigin?,
    val status: PhoneSkillStatus, val updatedAt: Long, val history: List<Long>, val fingerprint: String,
) {
    val body get() = document.render(status.state, source, from)
    // An outcome may promote a skill while another turn is using the same approved instructions.
    val readFingerprint get() = skillFingerprint(document.render("trial", "learned", null))
    fun targetSnapshot() = PhoneSkillBase(document.name, body, fingerprint)
    fun toMap(detail: Boolean = true): Map<String, Any?> = buildMap {
        put("name", document.name); put("display", document.display); put("description", document.description)
        put("whenToUse", document.whenToUse); put("apps", document.apps); put("source", source)
        put("state", status.state); put("uses", status.uses); put("recent", status.recent); put("updatedAt", updatedAt)
        put("suspensionReason", status.suspensionReason)
        if (from != null) put("learnedFrom", from.toMap())
        if (detail) { put("body", body); put("sections", document.sections); put("history", history) }
    }
}

internal data class PhoneSkillPending(
    val id: String, val document: PhoneSkillDocument, val from: PhoneSkillOrigin, val createdAt: Long,
    val source: String, val original: String?, val baseFingerprint: String?,
) {
    val kind get() = if (original == null) "new" else "update"
    val body get() = document.render(original?.let { PhoneSkillDocument.metadata(it)["state"] } ?: "trial", source, from)
    fun targetSnapshot() = PhoneSkillBase(document.name, body, skillFingerprint(body), id)
    fun toMap(): Map<String, Any?> = buildMap {
        put("id", id); put("name", document.name); put("kind", kind); put("display", document.display)
        put("description", document.description); put("whenToUse", document.whenToUse); put("apps", document.apps)
        put("sections", document.sections); put("body", body); put("createdAt", createdAt); put("from", from.toMap())
        if (original != null) {
            put("target", document.name); put("baseFingerprint", baseFingerprint)
            put("diff", skillLineDiff(original, body))
        }
    }

    fun disk() = mapOf("id" to id, "body" to body, "createdAt" to createdAt,
        "original" to original, "baseFingerprint" to baseFingerprint)
}

internal data class PhoneSkillListing(val skills: List<PhoneSkillSaved>, val drafts: List<PhoneSkillPending>,
    val legacy: List<Map<String, String>>, val archived: List<String>) {
    fun toMap(learn: Boolean) = mapOf("learn" to learn, "skills" to skills.map { it.toMap(false) },
        "drafts" to drafts.map { it.toMap() }, "legacy" to legacy, "archived" to archived)
}

internal data class PhoneSkillResult(val skill: PhoneSkillSaved, val change: String?)

/** Line LCS with linear auxiliary space. Changes on either side of unchanged lines stay separate. */
internal fun skillLineDiff(original: String, updated: String): List<Map<String, String>> {
    val old = original.trimEnd('\n').lines()
    val new = updated.trimEnd('\n').lines()
    val output = mutableListOf<Map<String, String>>()
    fun emit(op: String, text: String) { output += mapOf("op" to op, "text" to text) }
    fun lengths(a: Int, z: Int, b: Int, y: Int, reverse: Boolean): IntArray {
        val row = IntArray(y - b + 1)
        for (i in 0 until z - a) {
            var diagonal = 0
            for (j in 1..y - b) {
                val previous = row[j]
                val equal = old[if (reverse) z - i - 1 else a + i] == new[if (reverse) y - j else b + j - 1]
                row[j] = if (equal) diagonal + 1 else maxOf(row[j - 1], previous)
                diagonal = previous
            }
        }
        return row
    }
    fun split(a: Int, m: Int, z: Int, b: Int, y: Int): Int {
        val left = lengths(a, m, b, y, false)
        val right = lengths(m, z, b, y, true)
        return b + left.indices.maxBy { left[it] + right[y - b - it] }
    }
    fun compare(a: Int, z: Int, b: Int, y: Int) {
        when {
            a == z -> for (j in b until y) emit("+", new[j])
            b == y -> for (i in a until z) emit("-", old[i])
            a + 1 == z -> {
                val match = (b until y).firstOrNull { old[a] == new[it] }
                if (match == null) emit("-", old[a])
                for (j in b until y) emit(if (j == match) " " else "+", new[j])
            }
            else -> {
                val m = (a + z) / 2
                val p = split(a, m, z, b, y)
                compare(a, m, b, p)
                compare(m, z, p, y)
            }
        }
    }
    compare(0, old.size, 0, new.size)
    return output
}
