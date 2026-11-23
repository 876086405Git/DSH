package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.Json
import java.security.MessageDigest

/** Stable, content-free channel errors; never put the rejected text in detail. */
internal class PhoneSkillProblem(val code: String, val detail: String) : Exception(detail)

internal fun invalidSkill(detail: String): Nothing = throw PhoneSkillProblem("invalid", detail)
internal fun changedSkill(): Nothing = throw PhoneSkillProblem("changed", "The original skill has changed.")

internal data class PhoneSkillOrigin(val sessionId: String, val taskId: Long) {
    init {
        if (sessionId.isEmpty() || sessionId.length > 256 || sessionId.any { it < ' ' || it == '\u007f' } || taskId <= 0)
            invalidSkill("Invalid task origin.")
    }

    fun toMap() = mapOf("sessionId" to sessionId, "taskId" to taskId)
    companion object {
        fun parse(value: String): PhoneSkillOrigin {
            val task = value.substringAfterLast('/', "").toLongOrNull() ?: invalidSkill("Invalid task origin.")
            return PhoneSkillOrigin(value.substringBeforeLast('/'), task)
        }
    }
}

/** Our deliberately small frontmatter dialect accepts plain or JSON-quoted scalars and an inline
 * package-name list. Generated text is always quoted where YAML could interpret user punctuation. */
internal data class PhoneSkillDocument(
    val name: String, val display: String, val description: String, val whenToUse: String,
    val apps: List<String>, val sections: Map<String, String>, val english: Boolean = false,
) {
    fun render(state: String, source: String, from: PhoneSkillOrigin?): String = buildString {
        append("---\nname: ").append(name)
        append("\ndescription: ").append(Json.write(description))
        append("\nwhen-to-use: ").append(Json.write(whenToUse))
        append("\ndisplay: ").append(Json.write(display))
        append("\napps: ").append(Json.write(apps))
        append("\nsource: ").append(source).append("\nstate: ").append(state)
        // Invocation is granted only by the scoped native provider; filesystem copies remain inert.
        append("\ndisable-model-invocation: true\nuser-invocable: false")
        if (from != null) append("\nlearned-from: ").append(Json.write(from.sessionId + "/" + from.taskId))
        append("\n---\n")
        for ((key, heading) in if (english) englishHeadings else chineseHeadings) {
            append("\n## ").append(heading).append('\n').append(sections.getValue(key)).append('\n')
        }
    }

    companion object {
        val chineseHeadings = linkedMapOf("entry" to "入口", "steps" to "步骤", "pitfalls" to "容易出错的地方",
            "success" to "怎样算办成", "handoff" to "什么时候停下交给你")
        val englishHeadings = linkedMapOf("entry" to "Entry", "steps" to "Steps", "pitfalls" to "Pitfalls",
            "success" to "Success criteria", "handoff" to "When to hand off")
        private val fields = setOf("name", "description", "when-to-use", "display", "apps", "source", "state",
            "learned-from", "updates", "disable-model-invocation", "user-invocable")
        val legacyName = Regex("phone-task-[a-f0-9]{32}")
        private val slug = Regex("phone-[a-z]+(?:-[a-z]+)*")
        fun validName(value: String) = value.length <= 64 && slug.matches(value) && !legacyName.matches(value)

        private fun lines(markdown: String): List<String> {
            if (markdown.length > 32 * 1024) invalidSkill("Skill is too long.")
            return markdown.replace("\r\n", "\n").lines()
        }

        private fun endOfHeader(lines: List<String>): Int {
            if (lines.firstOrNull() != "---") invalidSkill("Expected frontmatter.")
            val end = lines.drop(1).indexOf("---")
            if (end < 0) invalidSkill("Unclosed frontmatter.")
            return end + 1
        }

        private fun scalar(value: String): String {
            if (value.startsWith('"')) {
                return try { Json.parseStrict(value) as? String ?: invalidSkill("Invalid string.") }
                    catch (_: Json.JsonException) { invalidSkill("Invalid quoted string.") }
            }
            if (value.startsWith('\'')) {
                if (value.length < 2 || !value.endsWith('\'')) invalidSkill("Invalid quoted string.")
                return value.substring(1, value.length - 1).replace("''", "'")
            }
            return value
        }

        private fun header(lines: List<String>, end: Int): Map<String, String> {
            val result = linkedMapOf<String, String>()
            for (line in lines.subList(1, end)) {
                if (line.isBlank()) continue
                val key = line.substringBefore(':')
                if (!line.contains(':') || key !in fields || result.containsKey(key)) invalidSkill("Invalid frontmatter field.")
                val value = line.substringAfter(':').trim()
                result[key] = if (key == "apps") value else scalar(value)
            }
            return result
        }

        fun metadata(markdown: String): Map<String, String> {
            val lines = lines(markdown)
            return header(lines, endOfHeader(lines))
        }

        fun parseMarkdown(markdown: String): PhoneSkillDocument {
            val lines = lines(markdown)
            val end = endOfHeader(lines)
            val meta = header(lines, end)
            fun field(name: String) = meta[name]?.takeIf { it.isNotBlank() }
                ?: invalidSkill("Missing " + name + ".")
            val appList = field("apps")
            if (!appList.startsWith('[') || !appList.endsWith(']')) invalidSkill("Expected a package list.")
            val apps = appList.drop(1).dropLast(1).trim().let { items ->
                if (items.isEmpty()) emptyList() else items.split(',').map { scalar(it.trim()) }
            }
            val body = lines.drop(end + 1)
            val starts = body.indices.filter { body[it].startsWith("## ") }
            val headings = starts.map { body[it].removePrefix("## ").trim() }
            val keys = when (headings) {
                englishHeadings.values.toList() -> englishHeadings
                chineseHeadings.values.toList() -> chineseHeadings
                else -> invalidSkill("Expected the five skill sections in order.")
            }
            if (body.take(starts.first()).any { it.isNotBlank() }) invalidSkill("Unexpected text before sections.")
            val sections = keys.keys.mapIndexed { index, key ->
                key to body.subList(starts[index] + 1, starts.getOrElse(index + 1) { body.size }).joinToString("\n").removeSuffix("\n")
            }.toMap()
            return PhoneSkillDocument(field("name"), field("display"), field("description"), field("when-to-use"),
                apps, sections, keys === englishHeadings)
        }
    }
}

internal fun skillFingerprint(markdown: String): String = MessageDigest.getInstance("SHA-256")
    .digest(markdown.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

/** Exact original bytes for compare-and-set; only sanitized versions are ever used for a diff. */
internal data class PhoneSkillBase(val name: String, val body: String, val fingerprint: String, val draftId: String? = null)
