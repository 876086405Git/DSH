package io.github.ccch1mneyyy.dsh_app.runtime

/** Credential masking before engine output enters the run tail or the disk logger. */
class LogRedactor {
    // One instance per stdout/stderr pump, so an unfinished key cannot leak its next line.
    private var privateKeyLines = 0

    /** Only PEM needs stream state; the disk logger masks all other formats once. */
    fun line(raw: String): String {
        // A malformed BEGIN must not hide the rest of this run's failure evidence.
        if (privateKeyLines >= PRIVATE_KEY_LINES) privateKeyLines = 0
        val text = ANSI.replace(raw, "")
        val out = StringBuilder()
        var at = 0
        while (at < text.length || privateKeyLines != 0) {
            if (privateKeyLines != 0) {
                val end = KEY_END.find(text, at)
                if (end == null) {
                    privateKeyLines++
                    return out.append(MARK).toString()
                }
                if (end.range.first > at) out.append(MARK)
                out.append(end.value)
                at = end.range.last + 1
                privateKeyLines = 0
            } else {
                val begin = KEY_BEGIN.find(text, at)
                if (begin == null) {
                    if (at == 0) return text
                    return out.append(text.substring(at)).toString()
                }
                out.append(text, at, begin.range.first)
                val end = KEY_END.find(text, begin.range.last + 1)
                if (end == null) {
                    privateKeyLines = 1
                    return out.append(begin.value).toString()
                }
                out.append(MARK)
                at = end.range.last + 1
            }
        }
        return out.toString()
    }

    companion object {
        private const val MARK = "•••"
        private const val PRIVATE_KEY_LINES = 128
        private const val MAX_LINE_LENGTH = 2000
        // ECMAScript \s, shared with Dart. Android's ICU and host JVM defaults differ.
        private const val SPACE = "\u0009\u000A\u000B\u000C\u000D\u0020\u00A0\u1680" +
            "\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A" +
            "\u2028\u2029\u202F\u205F\u3000\uFEFF"
        private val ANSI = Regex("""\x1B\[[0-9;?]*[ -/]*[@-~]""")
        private val KEY_BEGIN = Regex("""-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY-----""")
        private val KEY_END = Regex("""-----END [A-Z0-9 ]{0,40}PRIVATE KEY-----""")
        private val KEY_BLOCK = Regex("""${KEY_BEGIN.pattern}[\s\S]*?(?:${KEY_END.pattern}|\z)""")
        private val ADDRESS = Regex("""(?<![A-Za-z0-9_])[a-z][a-z0-9+.-]{1,15}://[^${SPACE}/:@?#]{0,256}:([^${SPACE}/@?#]+)@""")
        // Different run classes can overlap; scan each before merging the ranges.
        private val PROVIDERS = listOf(
            """sk-(?=[A-Za-z0-9_-]{0,255}[0-9])[A-Za-z0-9_-]{20,}|glpat-[A-Za-z0-9_-]{20,}""",
            """gh[pousr]_[A-Za-z0-9]{36,}|npm_[A-Za-z0-9]{36,}|hf_[A-Za-z0-9]{30,}|""" +
                """(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{24,}|""" +
                """(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9_])|LTAI[A-Za-z0-9]{12,20}(?![A-Za-z0-9_])|""" +
                """AKID[A-Za-z0-9]{28,36}(?![A-Za-z0-9_])""",
            """github_pat_[A-Za-z0-9_]{22,}""",
            """xox[abprs]-[A-Za-z0-9-]{10,}""",
        ).map { Regex("""(?<![A-Za-z0-9_])(?:$it)""") }
        // These shapes can also overlap themselves; capture without consuming them.
        private val OVERLAPPING_PROVIDER = Regex(
            """(?<![A-Za-z0-9_])(?=(AIza[A-Za-z0-9_-]{35}|""" +
                """eyJ[A-Za-z0-9_-]{8,2048}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}))""",
        )
        private val PREFIXES = listOf(
            "github_pat_", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "whsec_", "glpat-",
            "xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
            "npm_", "hf_", "sk-", "AIza", "AKIA", "ASIA", "LTAI", "AKID",
        )
        private val AUTH = Regex("""(?<![A-Za-z0-9_])(Bearer|Basic)[$SPACE]+(?!•)[A-Za-z0-9._~+/=-]+""", RegexOption.IGNORE_CASE)
        private val AUTH_SCHEME = Regex("""^(?:Bearer|Basic)$""", RegexOption.IGNORE_CASE)
        private val MASKED_AUTH = Regex("""^(?:Bearer|Basic)[$SPACE]+•••$""", RegexOption.IGNORE_CASE)
        private val INLINE_SPACE = SPACE.filterNot { it == '\r' || it == '\n' }
        private val ASSIGNMENT = Regex(
            """(?<![A-Za-z0-9_])([A-Za-z0-9_.-]*(?:passw(?:or)?d|passphrase|secret|credential|cookie|authorization|api[_-]?key|apikey|access[_-]?key|private[_-]?key|token)[A-Za-z0-9_.-]*)("?[$INLINE_SPACE]*[:=])""",
            RegexOption.IGNORE_CASE,
        )
        // `name=` at the end of a word is base64 padding (`YWJj=`), not an empty next field.
        private val NEXT_ASSIGNMENT = Regex("""[A-Za-z0-9_.-]+"?[$INLINE_SPACE]*(?:=(?![=$SPACE]|\z)|:(?=[$INLINE_SPACE]))""")
        private val SECRET_NAME = Regex("""passw(?:or)?d|passphrase|secret|credential|cookie|authorization""", RegexOption.IGNORE_CASE)
        // Explicit credential names do not use value length or numeric content as a proxy.
        // Use the live log's token-name rule, including its count/cursor exclusions.
        private val CREDENTIAL_KEY = Regex(
            """(?:.*[_.-])?(?:api[_-]?key|access[_-]?key|private[_-]?key)|${CrashClassifier.TOKEN_NAME}""",
            RegexOption.IGNORE_CASE,
        )

        /** Full disk/diagnostics masking; the live log keeps its separate token-only rule. */
        fun redact(raw: String): String {
            var text = ANSI.replace(raw, "")
            if (text.length > MAX_LINE_LENGTH) {
                text = text.split('\n').joinToString("\n") { line ->
                    if (line.length <= MAX_LINE_LENGTH) line else {
                        var end = MAX_LINE_LENGTH
                        if (line[end - 1] in '\uD800'..'\uDBFF' && line[end] in '\uDC00'..'\uDFFF') end--
                        line.substring(0, end) + "…"
                    }
                }
            }
            val spans = mutableListOf<IntRange>()
            KEY_BLOCK.findAll(text).forEach { spans.add(it.range) }
            PROVIDERS.forEach { pattern -> pattern.findAll(text).forEach { spans.add(it.range) } }
            OVERLAPPING_PROVIDER.findAll(text).forEach { spans.add(it.groups[1]!!.range) }
            ADDRESS.findAll(text).forEach { spans.add(it.groups[1]!!.range) }
            if (spans.isNotEmpty()) {
                val merged = mutableListOf<IntRange>()
                for (span in spans.sortedBy { it.first }) {
                    val previous = merged.lastOrNull()
                    if (previous != null && span.first <= previous.last) {
                        merged[merged.lastIndex] = previous.first..maxOf(previous.last, span.last)
                    } else merged.add(span)
                }
                val out = StringBuilder()
                var at = 0
                for (span in merged) {
                    out.append(text, at, span.first).append(mask(text.substring(span)))
                    at = span.last + 1
                }
                text = out.append(text, at, text.length).toString()
            }
            text = CrashClassifier.redact(text)
            text = AUTH.replace(text) { "${it.groupValues[1]} $MARK" }
            return assignments(text)
        }

        // Keep quoted values, including a value cut before its closing quote, in one mask.
        // The linear scan also avoids a repeated regex group's host-JVM recursion.
        private fun assignments(text: String): String {
            val out = StringBuilder()
            var copied = 0
            var cursor = 0
            while (true) {
                val match = ASSIGNMENT.find(text, cursor) ?: break
                val name = match.groupValues[1]
                val start = match.range.last + 1
                var at = start
                while (at < text.length && text[at] in INLINE_SPACE) at++
                val cookieHeader = (name.equals("cookie", true) || name.equals("set-cookie", true)) &&
                    match.groupValues[2].endsWith(':') && !match.groupValues[2].startsWith('"')
                // An empty assignment must not eat the next field or cross a log line.
                if (!cookieHeader && at > start && assignmentAt(text, at)) {
                    cursor = at
                    continue
                }
                val quote = text.getOrNull(at)?.takeIf { !cookieHeader && (it == '\'' || it == '"') }
                if (quote != null) at++
                val valueStart = at
                if (quote != null) {
                    while (at < text.length && text[at] != quote && text[at] != '\r' && text[at] != '\n') {
                        if (text[at] == '\\') {
                            if (at + 1 == text.length || text[at + 1] == '\r' || text[at + 1] == '\n') {
                                at++
                                break
                            }
                            at++
                        }
                        at++
                    }
                } else if (cookieHeader) {
                    while (at < text.length && text[at] != '\r' && text[at] != '\n') at++
                } else {
                    val jsonValue = text.getOrNull(match.range.first - 1) == '"' &&
                        match.groupValues[2].startsWith('"') && match.groupValues[2].endsWith(':')
                    while (at < text.length && text[at] !in SPACE && text[at] !in "\"',;&" &&
                        (!jsonValue || text[at] !in "}]")) at++
                    val markedEnd = maskedEnd(text, valueStart)
                    val queryToken = name.equals("token", true) && match.range.first > 0 &&
                        text[match.range.first - 1] in "?&#"
                    if (markedEnd > valueStart && (assignmentAt(text, markedEnd) ||
                        (queryToken && markedEnd < at && (text[markedEnd] == '#' ||
                            (text[markedEnd] == ')' && markedEnd + 1 == at))))) {
                        at = markedEnd
                    }
                }
                if (quote == null && !cookieHeader && text.getOrNull(match.range.first - 1) == '(' &&
                    at > valueStart && text[at - 1] == ')') {
                    at--
                }
                val value = text.substring(valueStart, at)
                val secret = SECRET_NAME.containsMatchIn(name)
                val authorization = name.endsWith("authorization", true)
                val alreadyMasked = value == MARK || (!secret && maskedEnd(value, 0) == value.length) ||
                    (authorization && (MASKED_AUTH.matches(value) || (quote == null && AUTH_SCHEME.matches(value))))
                if (value.isNotEmpty() && !alreadyMasked &&
                    (secret || CREDENTIAL_KEY.matches(name) ||
                        (!name.endsWith("token", true) && value.length >= 8 && value.any { it !in '0'..'9' }))) {
                    out.append(text, copied, valueStart).append(MARK)
                    copied = at
                    cursor = if (quote != null && text.getOrNull(at) == quote) at + 1 else at
                } else {
                    // A value left readable (a cursor that is a URL) can carry a credential of its own.
                    cursor = valueStart
                }
            }
            if (copied == 0) return text
            return out.append(text, copied, text.length).toString()
        }

        // A generic URI scheme is a value, not an empty field followed by an assignment.
        private fun assignmentAt(text: String, start: Int): Boolean =
            NEXT_ASSIGNMENT.find(text, start)?.range?.first == start ||
                ASSIGNMENT.find(text, start)?.range?.first == start

        private fun maskedEnd(text: String, start: Int): Int {
            if (text.startsWith(MARK, start)) return start + MARK.length
            val prefix = PREFIXES.firstOrNull { text.startsWith(it + MARK, start) } ?: return start
            return start + prefix.length + MARK.length
        }

        private fun mask(value: String): String {
            if (value.startsWith("-----BEGIN")) {
                val begin = KEY_BEGIN.find(value)?.value ?: return MARK
                if (value == begin) return begin
                if (!value.contains('\n')) return MARK
                val end = KEY_END.find(value)?.value
                return begin + "\n$MARK" + (end?.let { "\n$it" } ?: "")
            }
            return (PREFIXES.firstOrNull { value.startsWith(it) } ?: "") + MARK
        }
    }
}
