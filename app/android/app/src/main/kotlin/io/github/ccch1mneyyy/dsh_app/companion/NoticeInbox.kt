package io.github.ccch1mneyyy.dsh_app.companion

import io.github.ccch1mneyyy.dsh_app.phone.SensitiveWords
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import java.text.Normalizer

/** A package observation may update the picker before its level permits reading any Notification fields. */
internal data class NoticeAccess(val enabled: Boolean, val granted: Boolean, val unlocked: Boolean) {
    val open get() = enabled && granted && unlocked
    fun reads(level: String) = open && (level == "glance" || level == "remember")
}

internal enum class NoticeBinding { UNBIND, REBIND, KEEP }

internal fun noticeBinding(access: NoticeAccess, connected: Boolean): NoticeBinding = when {
    connected && !access.open -> NoticeBinding.UNBIND
    !connected && access.open -> NoticeBinding.REBIND
    else -> NoticeBinding.KEEP
}

internal object NoticeFilter {
    private val blocked = setOf("transport", "call", "missed_call", "alarm", "navigation", "stopwatch", "timer", "progress", "service")
    private val invisible = Regex("[\\p{Cc}\\p{Cf}&&[^\\t\\n\\r]]")
    private val whitespace = Regex("[\\s\\p{Z}]+")
    // l10n:keep external notification content, including traditional Chinese.
    private val secretTerms = listOf("驗證碼", "密碼", "校驗碼", "動態碼", "安全碼", "登入碼", "登录码", "認證碼", "认证码")
    private val separators = Regex("[\\t\\n\\r]+")
    // Split format/control characters must not hide credential labels.
    private val credential = Regex("""(?i)\b(?:security|login|sign[ -]?in|authentication|confirmation)\s+code\b|\bone\s+time\b|\bcode\b.{0,24}\b\d{4,8}\b|\b\d{4,8}\b.{0,24}\b(?:code|verify)\b|\bcode\b.{0,24}\b\d{3}[ -]\d{3}\b|\bcode\b.{0,24}\b(?=[a-z0-9]{4,10}\b)(?=[a-z]*\d)[a-z\d]*[a-z][a-z\d]*\b""")

    fun acceptsCategory(category: String?, ongoing: Boolean, foreground: Boolean) =
        !ongoing && !foreground && category !in blocked

    /** Read the full visible fields for secret markers before choosing a preview or truncating it. */
    fun segment(fields: List<CharSequence>): String? {
        val parts = LinkedHashSet<String>()
        for (field in fields) {
            val plain = Normalizer.normalize(field, Normalizer.Form.NFKC)
            val clean = invisible.replace(plain, "")
            val text = whitespace.replace(clean, " ").trim()
            val compact = separators.replace(clean, "")
            if (SensitiveWords.secretHit(text, compact, null) != null ||
                secretTerms.any { compact.contains(it) } || credential.containsMatchIn(text)) return null
            if (text.isNotEmpty()) parts.add(text)
        }
        val text = parts.joinToString(" · ")
        if (text.isEmpty()) return null
        // A code can be split across fields (title 「你的验证码」, text 「123456」): check them together too.
        val joined = separators.replace(text, "")
        if (SensitiveWords.secretHit(text, joined, null) != null ||
            secretTerms.any { joined.contains(it) } || credential.containsMatchIn(text)) return null
        val length = text.codePointCount(0, text.length).coerceAtMost(500)
        return text.substring(0, text.offsetByCodePoints(0, length))
    }
}

internal class NoticeIds(secret: ByteArray) {
    private val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(secret, "HmacSHA256")) }

    fun digest(domain: String, value: String): String {
        val alphabet = "0123456789abcdef"
        return buildString(64) {
            for (byte in mac.doFinal((domain + "\u0000" + value).toByteArray(Charsets.UTF_8))) {
                append(alphabet[(byte.toInt() and 255) ushr 4])
                append(alphabet[byte.toInt() and 15])
            }
        }
    }
}

/** Main-thread owned. No Android notification, tag, PendingIntent or original text reaches storage. */
internal class NoticeInbox {
    data class Segment(val text: String, val atMs: Long, val personId: String?)
    data class Entry(val pkg: String, val key: String, val queuedMs: Long, val segments: ArrayDeque<Segment> = ArrayDeque())

    private val entries = linkedMapOf<String, Entry>()

    fun add(pkg: String, key: String, queuedMs: Long, postedMs: Long, text: String, personId: String? = null): Boolean {
        val entry = entries.getOrPut(key) { Entry(pkg, key, queuedMs) }
        val last = entry.segments.lastOrNull()
        if (last?.text == text && last.personId == personId) return false
        entry.segments.addLast(Segment(text, postedMs, personId))
        if (entry.segments.size > 10) entry.segments.removeFirst()
        if (entries.size > 200) entries.remove(entries.keys.first())
        return true
    }

    fun pending() = entries.values.map { mapOf("pkg" to it.pkg, "key" to it.key, "atMs" to it.queuedMs) }

    fun take(pkg: String, keys: List<String>): List<Entry> {
        require(keys.size in 1..8)
        return keys.mapNotNull { key ->
            if (entries[key]?.pkg == pkg) entries.remove(key) else null
        }
    }

    fun keys(): List<String> = entries.keys.toList()

    fun clear(pkg: String? = null) {
        if (pkg == null) entries.clear() else entries.values.removeAll { it.pkg == pkg }
    }
}

/** Metadata survives a lock in this process. Counters and active-notification replay have different lifetimes. */
internal class NoticePosts {
    private data class Post(val at: Long, var captured: Boolean = false, var counted: Boolean = false)
    private val posts = linkedMapOf<String, Post>()

    fun observe(key: String, at: Long): Boolean {
        if (posts[key]?.at == at) return false
        posts.remove(key)
        posts[key] = Post(at)
        if (posts.size > 2048) posts.remove(posts.keys.first())
        return true
    }

    fun captured(key: String) = posts[key]?.captured == true
    fun markCaptured(key: String): Boolean {
        val post = posts.getValue(key)
        val restoring = post.counted && !post.captured
        post.captured = true
        post.counted = true
        return !restoring
    }
    fun forgetPending(keys: List<String>) { keys.forEach { posts[it]?.captured = false } }
    fun clear() = posts.clear()
}
