package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.PhoneToolCatalog
import io.github.ccch1mneyyy.dsh_app.phone.SensitiveWords
import java.text.Normalizer

/** Shared by model proposals and edits. Errors identify fields, never their original contents. */
internal object PhoneSkillValidation {
    private const val PARAM = "<参数>"
    private val quoted = Regex("""“[^”\n]*”|‘[^’\n]*’|「[^」\n]*」|『[^』\n]*』|"[^"\n]*"|(?<![\p{L}\p{N}])'[^'\n]*'(?![\p{L}\p{N}])""")
    private val url = Regex("""(?i)\b(?:[a-z][a-z0-9+.\-]*://|www\.)[^\s<>]+""")
    private val email = Regex("""[\w.+%-]+@[\w.-]+\.[A-Za-z]{2,}""")
    private val amount = Regex("""(?i)(?:\p{Sc}|USD|CNY|RMB|EUR|GBP|HKD)\s*[-+]?\s*\p{Nd}[\p{Nd}.,]*|(?<![\p{Nd}.,])[-+]?\p{Nd}[\p{Nd}.,]*\s*(?:\p{Sc}|(?:美元|人民币|港元|欧元|英镑|元|块钱|块|角|毛|分(?!钟))|(?:USD|CNY|RMB|EUR|GBP|HKD|dollars?|yuan|euros?|pounds?)\b)|[零〇一二两三四五六七八九十百千万亿点壹贰叁肆伍陆柒捌玖拾佰仟萬億]+(?:美元|欧元|英镑|港元|块钱|块|元|角|毛|分(?!钟))""")
    private val numberGroup = Regex("""\+?\p{Nd}(?:[ ().-]*\p{Nd}){3,14}""")
    private val digits = Regex("""\p{Nd}+(?:[.,]\p{Nd}+)+|\p{Nd}{2,}""")
    private val assignedCredential = Regex("""(?im)(?<![\w])(?:[a-z]+[_-])*(?:api[_ -]?key|secret|token|password|passwd|authorization|(?:set-)?cookie|密钥|令牌|密码)["']?[ \t]*[:=][ \t]*[^\r\n]+""")
    private val tokenValue = Regex("""(?i)(?:\bsk-[a-z0-9_-]{16,}|\bgh[pousr]_[a-z0-9_]{16,}|\bgithub_pat_[a-z0-9_]{16,}|\b(?:bearer|basic)[ \t]+[a-z0-9./_+~=-]{8,})""")
    private val tool = Regex("""(?i)(?<![\w.])(?:mcp__phone__|phone\.)([a-z_][a-z0-9_-]*)""")
    private val secretMarker = Regex("""(?i)\b(?:api[_ -]?key|access[_ -]?token|passwd|pwd|sms[_ -]?code|auth[_ -]?code|verify[_ -]?code)\b""")
    private val packageToken = Regex("""(?<![\w.])[a-zA-Z][\w]*(?:\.[a-zA-Z][\w]*)+(?![\w.])""")

    fun clean(document: PhoneSkillDocument): PhoneSkillDocument {
        if (!PhoneSkillDocument.validName(document.name))
            invalid("name")
        if (document.apps.any { PhoneTaskTrace.safePackage(it) == null } ||
            document.apps.size != document.apps.distinct().size) invalid("apps")
        if (SensitiveWords.secretHit(document.name, null, document.name) != null)
            throw PhoneSkillProblem("sensitive", "name")
        if (document.sections.keys != PhoneSkillDocument.chineseHeadings.keys) invalid("sections")
        val body = document.render("trial", "learned", null).substringAfter("\n---\n")
        if (body.codePointCount(0, body.length) > 4000) invalid("sections")
        val param = if (document.english) "<parameter>" else PARAM
        fun field(key: String, value: String, multiline: Boolean = false): String {
            val text = value.replace("\r\n", "\n").trim()
            val normalized = Normalizer.normalize(text, Normalizer.Form.NFKC)
            if (normalized.isBlank() || normalized.any { it.isISOControl() && !(multiline && it in "\n\t") } ||
                !multiline && normalized.any { it == '\u2028' || it == '\u2029' } ||
                multiline && normalized.lineSequence().any { it.trimStart().startsWith("## ") }) invalid(key)
            if (SensitiveWords.secretHit(normalized, null, null) != null || secretMarker.containsMatchIn(normalized))
                throw PhoneSkillProblem("sensitive", key)
            for (mention in tool.findAll(normalized)) {
                if (mention.groupValues[1] !in PhoneToolCatalog.names) invalid(key)
            }
            return redact(text, document.apps, param)
        }
        val clean = document.copy(
            display = field("display", document.display),
            description = field("description", document.description),
            whenToUse = field("when-to-use", document.whenToUse),
            sections = document.sections.mapValues { (key, value) -> field(key, value, multiline = true) },
        )
        val cleanBody = clean.render("trial", "learned", null).substringAfter("\n---\n")
        if (cleanBody.codePointCount(0, cleanBody.length) > 4000) invalid("sections")
        return clean
    }

    /** Early templates include safety instructions about secret fields. Preserve their instructions
     * while removing private values from both the archived description and body. */
    fun redactLegacy(text: String): String = redact(text, emptyList(), PARAM)

    private fun redact(text: String, apps: List<String>, param: String): String {
        fun mask(value: String): String {
            val withoutCredentials = tokenValue.replace(assignedCredential.replace(value, param), param)
            val withoutValues = email.replace(url.replace(quoted.replace(withoutCredentials, param), param), param)
            return buildString {
                var start = 0
                for (match in packageToken.findAll(withoutValues)) {
                    if (match.value !in apps) continue
                    append(maskNumbers(withoutValues.substring(start, match.range.first), param))
                    append(match.value)
                    start = match.range.last + 1
                }
                append(maskNumbers(withoutValues.substring(start), param))
            }
        }
        val masked = mask(text)
        val normalized = Normalizer.normalize(masked, Normalizer.Form.NFKC)
        if (masked == normalized) return masked
        // Retain original punctuation and characters unless normalization exposes a disguised value.
        val checked = mask(normalized)
        return if (checked == normalized) masked else checked
    }

    private fun maskNumbers(value: String, param: String): String =
        digits.replace(numberGroup.replace(amount.replace(value, param), param), param)

    private fun invalid(field: String): Nothing = throw PhoneSkillProblem("invalid", field)
}
