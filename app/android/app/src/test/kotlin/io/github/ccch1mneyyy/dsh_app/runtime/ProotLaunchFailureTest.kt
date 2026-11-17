package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.*
import org.junit.Test

class ProotLaunchFailureTest {
    private val execErrors = listOf(
        "proot error: execve(\"/usr/bin/env\"): Permission denied",
        "proot error: execve(\"/usr/bin/env\"): Too many symbolic links encountered",
    )
    private val envShellError = "/usr/bin/env: '/bin/sh': No such file or directory"

    private val prootAssertion =
        "./tracee/event.c:704: int handle_tracee_event(Tracee *, int): assertion \"IS_IN_SYSENTER(tracee)\" failed"
    private val reported = execErrors + prootAssertion

    private fun classify(
        tail: List<String>,
        readyAt: Long? = null,
        exitCode: Int = 1,
        safe: Boolean = false,
        direct: Boolean = false,
    ) = CrashClassifier.classify(exitCode, readyAt, 180_000L, 123L, tail, safe, direct)

    @Test fun preservesTheReportedEnvShellFailureWithoutCallingItAnAndroidKill() {
        val failure = classify(listOf(envShellError), exitCode = 127)
        assertEquals(FailureKind.LAUNCH_FAILED, failure.kind)
        assertEquals(envShellError, failure.summary)
        assertFalse(failure.kind.counts)
    }

    @Test fun onlyAcceptsTheEnvShellFailureBeforeReadyOnAnExit127ProotRun() {
        assertEquals(FailureKind.KILLED, classify(listOf(envShellError), readyAt = 0L, exitCode = 127).kind)
        assertEquals(FailureKind.KILLED, classify(listOf(envShellError), exitCode = 127, direct = true).kind)
        for (code in listOf(0, 126)) {
            assertEquals(FailureKind.KILLED, classify(listOf(envShellError), exitCode = code).kind)
        }
        assertEquals(FailureKind.KILLED, classify(emptyList(), exitCode = 127).kind)
    }

    @Test fun envShellFailureKeepsDiskFullAndDshFatalEvidenceAhead() {
        assertEquals(FailureKind.NO_SPACE, classify(listOf(envShellError, "ENOSPC"), exitCode = 127).kind)
        val fatal = "dsh: startup failed: required row missing"
        val failure = classify(listOf(envShellError, fatal), exitCode = 127)
        assertEquals(FailureKind.STARTUP_FAILED, failure.kind)
        assertEquals("startup failed: required row missing", failure.summary)
    }

    @Test fun preservesReportedProotFailuresInsteadOfCallingThemAndroidKills() {
        for (error in reported) {
            val failure = classify(listOf(
                error,
                "proot info: possible causes:",
                "  * the loader was not found or doesn't work.",
                "fatal error: see `libproot.so --help`.",
            ))
            assertEquals(error, FailureKind.LAUNCH_FAILED, failure.kind)
            assertEquals(error, failure.summary)
            assertNull(failure.upSeconds)
            assertEquals("launchFailed", failure.toMap()["kind"])
        }
    }

    @Test fun onlyAcceptsKnownProotFailuresBeforeReadyOnAFailedProotRun() {
        for (error in reported) {
            assertEquals(FailureKind.KILLED, classify(listOf(error), readyAt = 0L).kind)
            assertEquals(FailureKind.KILLED, classify(listOf(error), exitCode = 0).kind)
            assertEquals(FailureKind.KILLED, classify(listOf(error), direct = true).kind)
            assertEquals(FailureKind.KILLED, classify(listOf("plugin says: $error")).kind)
        }
        for (error in execErrors) {
            assertEquals(FailureKind.KILLED, classify(listOf(error.replace("/usr/bin/env", "/tmp/plugin-helper"))).kind)
        }
        for (line in listOf(
            prootAssertion.replace("./tracee/event.c", "./plugin.c"),
            prootAssertion.replace("IS_IN_SYSENTER(tracee)", "plugin_state"),
            "Permission denied",
            "Too many symbolic links encountered",
            "proot error: can't chmod '/tmp/proot-file': No such file or directory",
            "proot error: execve(\"/usr/bin/env\"): unexpected plugin output",
            "  * the loader was not found or doesn't work.",
        )) assertEquals(line, FailureKind.KILLED, classify(listOf(line)).kind)
    }

    @Test fun diskFullAndDshFatalKeepTheirPriority() {
        val fatal = "dsh: startup failed: required row missing"
        for (error in reported) {
            assertEquals(FailureKind.NO_SPACE, classify(listOf(error, "ENOSPC")).kind)
            val failure = classify(listOf(error, fatal))
            assertEquals(FailureKind.STARTUP_FAILED, failure.kind)
            assertEquals("startup failed: required row missing", failure.summary)
        }
    }

    @Test fun environmentFailuresDoNotBlamePluginsOrTriggerRecoveryLoops() {
        for (error in reported) {
            for (safe in listOf(false, true)) {
                val failure = classify(listOf(error), safe = safe)
                assertEquals(FailureKind.LAUNCH_FAILED, failure.kind)
                assertFalse(failure.kind.counts)
                assertFalse(SafePolicy.directLaunchFailed(failure, direct = false))
                for (state in SafeState.entries) {
                    val outcome = SafePolicy.onFailure(state, 1, failure, true)
                    assertEquals(state, outcome.state)
                    assertEquals(1, outcome.strikes)
                    assertFalse(outcome.restartSafe)
                }
                assertNull(SafePolicy.autoRestartDelay(failure.kind, failure.exitCode, null, emptyList(), 180_000L))
                assertNull(SafePolicy.autoRestartDelay(failure.kind, failure.exitCode, 90_000L, emptyList(), 180_000L))
                val briefing = SafeMode.renderBriefing(SafeMode.Briefing(
                    failure = failure.copy(recent = listOf("unrelated-plugin"), requiredRows = listOf("unrelated-row")),
                    reason = SafePolicy.REASON_MANUAL, moved = emptyList(), lkgAt = null,
                    lkgBundles = emptyList(), lkgVersions = emptyMap(), failureLog = listOf(error),
                ))
                assertTrue(briefing.contains(error))
                assertFalse(briefing.contains("unrelated-plugin"))
                assertFalse(briefing.contains("unrelated-row"))
            }
        }
    }
}
