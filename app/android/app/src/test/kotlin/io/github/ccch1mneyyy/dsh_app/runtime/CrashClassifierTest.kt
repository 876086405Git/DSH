package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.*
import org.junit.Test

class CrashClassifierTest {
    @Test fun launchTokensDoNotHideCountsOrPaginationCursors() {
        val readable = "max_token=1024 prompt_token=5 next_token=page-cursor-123 maxOutputToken=1024 nextPageToken=page-cursor-123"
        assertEquals(readable, CrashClassifier.redact(readable))
        assertEquals("$readable token=••• access_token=••• GITHUB_TOKEN=•••",
            CrashClassifier.redact("$readable token=7 access_token=42 GITHUB_TOKEN=synthetic"))
    }

    @Test fun unknownCredentialNamesStayMaskedInLiveLogs() {
        for (name in listOf("VERCEL_TOKEN", "DISCORD_TOKEN", "TELEGRAM_TOKEN", "PYPI_TOKEN",
            "CODECOV_TOKEN", "CSRF_TOKEN", "client_token", "clientToken", "oauth_token",
            "x_auth_token", "gh_token", "bot_token", "ADMIN_TOKEN", "max_access_token")) {
            for (value in listOf("synthetic-value", "x", "7", "123:synthetic+value/x==")) {
                assertEquals(name, "$name=•••", CrashClassifier.redact("$name=$value"))
            }
        }
    }

    @Test fun repeatedTokenQualifiersAtTheLogLineLimit() {
        val count = "min".repeat(664) + "token=xy"
        assertEquals(2000, count.length)
        assertEquals(count, CrashClassifier.redact(count))
        assertEquals(count, LogRedactor.redact(count))
        val credential = "min".repeat(660) + "access_token=xy"
        val expected = credential.substringBefore('=') + "=•••"
        assertEquals(expected, CrashClassifier.redact(credential))
        assertEquals(expected, LogRedactor.redact(credential))
    }

    private val fatal = listOf("dsh: startup failed: required row missing")

    @Test fun classifiesAllFiveFailureKinds() {
        fun classify(ready: Long?, now: Long, tail: List<String>) =
            CrashClassifier.classify(137, ready, now, 123L, tail, false).kind
        assertEquals(FailureKind.KILLED, classify(1L, 180_000L, listOf("normal output")))
        assertEquals(FailureKind.STARTUP_FAILED, classify(null, 1L, fatal))
        assertEquals(FailureKind.CRASHED_EARLY, classify(1L, 120_001L, fatal))
        assertEquals(FailureKind.CRASHED_LATE, classify(1L, 120_002L, fatal))
        assertEquals(FailureKind.NO_SPACE, classify(null, 1L, fatal + "ENOSPC"))
    }

    @Test fun summariesNeverContainLaunchTokens() {
        val failure = CrashClassifier.classify(1, null, 1L, 1L,
            listOf("dsh: startup failed: http://localhost/?token=private-value"), false)
        assertFalse(failure.summary!!.contains("private-value"))
        assertTrue(failure.summary!!.contains("token="))
    }

    @Test fun tawcRecoveryMatchesTheObservedEarlyProotFailure() {
        val cwd = "sh: 0: getcwd() failed: Function not implemented"
        val exec = "/bin/sh: 1: exec: /usr/local/bin/dsh: Bad address"
        fun matches(code: Int, tail: List<String>, ready: Long? = null): Boolean {
            val failure = CrashClassifier.classify(code, ready, 100L, 100L, tail, false)
            return CrashClassifier.isProotCompatibilityFailure(failure, tail)
        }
        assertTrue(matches(126, listOf(cwd, exec)))
        assertFalse(matches(126, listOf(exec)))
        assertFalse(matches(127, listOf(cwd, "/usr/bin/env: '/bin/sh': No such file or directory")))
        assertFalse(matches(126, listOf(cwd, exec), ready = 1L))
        assertFalse(matches(126, listOf(cwd, exec, "No space left on device")))
    }
}
