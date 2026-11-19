package io.github.ccch1mneyyy.dsh_app.runtime

/**
 * Why the local DSH stopped when nobody asked it to.
 * DSH fatal markers and explicit early V8 heap exhaustion can count toward recovery.
 * An unmarked exit (low-memory kill, battery saver, child-process limits) never does.
 */
enum class FailureKind(val wire: String) {
    /** PRoot, the shell/loader or direct preload could not start DSH before ready. */
    LAUNCH_FAILED("launchFailed"),

    /** Exited with a fatal marker before the runtime reported ready. */
    STARTUP_FAILED("startupFailed"),

    /** Exited with a fatal marker within [CrashClassifier.EARLY_WINDOW_MS] of the ready transition. */
    CRASHED_EARLY("crashedEarly"),

    /** Exited with a fatal marker after running longer than that. */
    CRASHED_LATE("crashedLate"),

    /** Exited without a recognized startup/fatal marker; an external kill is possible. */
    KILLED("killed"),

    /** The output mentions a full disk. */
    NO_SPACE("noSpace");

    /** Counts toward the consecutive failures that lead into safe mode. */
    val counts: Boolean get() = this == STARTUP_FAILED || this == CRASHED_EARLY

    companion object {
        fun parse(wire: String?): FailureKind? = entries.firstOrNull { it.wire == wire }
    }
}

data class RunFailure(
    val kind: FailureKind,
    val exitCode: Int,
    /** Wall-clock time of the exit (ms). */
    val at: Long,
    /** The failed run was a safe-mode run. */
    val safeMode: Boolean,
    /** First fatal or launch error line, without the `dsh: ` prefix and with credentials masked. */
    val summary: String?,
    /** Required rows the startup audit names (`agent-loop (required)`): broken, not necessarily the culprit. */
    val requiredRows: List<String>,
    /** Third-party packages named by stack paths or `Package:` lines. */
    val suspects: List<String>,
    /** Bundles enabled or upgraded since the last good run (filled in by the controller). */
    val recent: List<String> = emptyList(),
    /** Guest path of DSH's startup diagnostics file, if it printed one. */
    val diagnostics: String?,
    /** Seconds between the ready transition and exit; null when ready was never reported. */
    val upSeconds: Long?,
    /** The guest shell couldn't resolve its working directory or execute DSH under PRoot. */
    val prootCompatibilityFailure: Boolean = false,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "kind" to kind.wire,
        "exitCode" to exitCode,
        "at" to at,
        "safeMode" to safeMode,
        "summary" to summary,
        "requiredRows" to requiredRows,
        "suspects" to suspects,
        "recent" to recent,
        "diagnostics" to diagnostics,
        "upSeconds" to upSeconds,
        "prootCompatibilityFailure" to prootCompatibilityFailure,
    )
}

/** Pure classification of one finished run from its exit code, timing and last output lines. */
object CrashClassifier {
    const val EARLY_WINDOW_MS = 120_000L

    /** Output lines kept per run for classification and the failure log. */
    const val TAIL_LINES = 300

    private val FATAL = listOf(
        Regex("^dsh: startup failed:"),
        Regex("^dsh: fatal (uncaught exception|load failure):"),
        // Thrown before startup proper: a malformed patch layer, a .env with a launch-only variable, ...
        Regex("^[A-Za-z]*Error: dsh: "),
        Regex("^dsh: profile startup and cleanup failed"),
    )
    private val HEAP_OOM = Regex(
        "^FATAL ERROR: (?:Reached heap limit|Ineffective mark-compacts near heap limit) " +
            "Allocation failed - JavaScript heap out of memory$",
    )
    private val NO_SPACE = Regex("ENOSPC|No space left on device")
    // Fixed executable and shell prefix: a plugin's generic error is not launch evidence.
    private val EXEC_FAILED = Regex(
        "^(?:/bin/)?(?:sh|bash|dash): (?:[0-9]+: )?exec: /usr/local/bin/dsh: " +
            "(?:Bad address|Exec format error|Permission denied|not found|Function not implemented|Operation not permitted)$",
    )
    // The first guest command failed before env or DSH could run; this is not an Android kill.
    private val PROOT_EXEC_FAILED = Regex(
        "^proot error: execve\\(\"/usr/bin/env\"\\): (?:Permission denied|Too many symbolic links encountered)$",
    )
    // The fixed guest env command could not execute its shell before DSH started.
    private const val ENV_SHELL_EXEC_FAILED = "/usr/bin/env: '/bin/sh': No such file or directory"
    // This exact early assertion comes from the pinned PRoot, not an Android kill.
    private const val PROOT_ASSERT_FAILED =
        "./tracee/event.c:704: int handle_tracee_event(Tracee *, int): assertion \"IS_IN_SYSENTER(tracee)\" failed"
    private val DIRECT_FAILED = listOf(
        Regex("^\\[dsh-app-direct] launch failed: .+"),
        Regex("^/.*/opt/node/bin/node: (?:error while loading shared libraries: .+|.+: version [`'].+['`] not found.*)$"),
        Regex("^/.*/ld-linux[^/: ]+\\.so(?:\\.[0-9]+)?: (?:cannot open shared object file|failed to map segment|invalid ELF header|ELF load command|cannot execute).*$"),
        Regex("^Error \\[ERR_MODULE_NOT_FOUND]: Cannot find module ['\"].*/opt/dsh-go/direct/(?:preload|dns|paths|processes|modules)\\.mjs['\"].*$"),
        Regex("^DshDirectModuleIdentityError: this file needs compatible launch; stop the engine and turn off Direct engine$"),
    )
    /**
     * 128 + SIGSYS: Android's seccomp filter killed the direct loader or node for a
     * syscall it forbids (glibc's `access` on x86_64). The kill prints nothing.
     */
    const val SIGSYS_EXIT = 128 + 31
    private const val SECCOMP_KILLED = "killed by the system's syscall filter (SIGSYS)"
    private val DIAGNOSTICS = Regex("^Full diagnostics: (\\S+)")
    private val REQUIRED_ROW = Regex("^\\s{2}(\\S+) \\(required\\)")
    private val PACKAGE = Regex("^\\s+Package: (\\S+)")
    // Singular token names are credentials except explicit counts and pagination cursors.
    internal const val TOKEN_NAME =
        "(?!(?:[A-Za-z0-9_.-]*[_.-])?" +
        "(?:(?:max|min|prompt|completion|input|output|next|prev|previous|continuation|page|cursor|total)[_-]?)+" +
        "token(?![A-Za-z0-9_.-]))[A-Za-z0-9_.-]*token"
    private val TOKEN = Regex("(?<![A-Za-z0-9_.-])($TOKEN_NAME)=[A-Za-z0-9._~%:+/=-]+", RegexOption.IGNORE_CASE)
    private const val WEB_MODULES = "/profiles/web/node_modules/"
    private const val SHIPPED_SCOPE = "@deepseek-ai/"
    private const val SUMMARY_MAX = 240

    /** A token deadline must not hide existing evidence, nor invent it for a silent loader. */
    fun classifyAfterTokenTimeout(tokenTimedOut: Boolean, failure: RunFailure): Boolean =
        tokenTimedOut && failure.kind in setOf(
            FailureKind.STARTUP_FAILED, FailureKind.NO_SPACE, FailureKind.LAUNCH_FAILED,
        )

    fun isFatal(line: String): Boolean = FATAL.any { it.containsMatchIn(line) }

    fun isProotCompatibilityFailure(failure: RunFailure, tail: List<String>): Boolean =
        failure.kind == FailureKind.LAUNCH_FAILED && failure.exitCode == 126 &&
            "sh: 0: getcwd() failed: Function not implemented" in tail &&
            "/bin/sh: 1: exec: /usr/local/bin/dsh: Bad address" in tail

    fun redact(line: String): String = TOKEN.replace(line) { "${it.groupValues[1]}=•••" }

    /**
     * [readyAt] and [now] share one monotonic clock (elapsedRealtime); [readyAt] is null when
     * the runtime never reported ready. [wallClock] only stamps the result.
     */
    fun classify(
        exitCode: Int,
        readyAt: Long?,
        now: Long,
        wallClock: Long,
        tail: List<String>,
        safeMode: Boolean,
        directEngine: Boolean = false,
    ): RunFailure {
        // V8 running out of heap while starting or just after counts like a DSH fatal (#75);
        // later it stays KILLED, which restarts. Neither names a culprit plugin.
        val early = exitCode != 0 && (readyAt == null || now - readyAt <= EARLY_WINDOW_MS)
        val fatal = tail.firstOrNull(::isFatal) ?: tail.firstOrNull { HEAP_OOM.matches(it) }?.takeIf { early }
        val launch = if (readyAt == null && exitCode != 0) tail.firstOrNull {
            EXEC_FAILED.matches(it) || (!directEngine && (PROOT_EXEC_FAILED.matches(it) || it == PROOT_ASSERT_FAILED ||
                (exitCode == 127 && it == ENV_SHELL_EXEC_FAILED))) ||
                (directEngine && DIRECT_FAILED.any { pattern -> pattern.matches(it) })
        } ?: (if (directEngine && exitCode == SIGSYS_EXIT) SECCOMP_KILLED else null) else null
        val kind = when {
            tail.any { NO_SPACE.containsMatchIn(it) } -> FailureKind.NO_SPACE
            fatal == null && launch != null -> FailureKind.LAUNCH_FAILED
            fatal == null -> FailureKind.KILLED
            readyAt == null -> FailureKind.STARTUP_FAILED
            now - readyAt <= EARLY_WINDOW_MS -> FailureKind.CRASHED_EARLY
            else -> FailureKind.CRASHED_LATE
        }
        val required = LinkedHashSet<String>()
        val suspects = LinkedHashSet<String>()
        var diagnostics: String? = null
        for (line in tail) {
            REQUIRED_ROW.find(line)?.let { required += it.groupValues[1] }
            PACKAGE.find(line)?.groupValues?.get(1)?.let { if (!it.startsWith(SHIPPED_SCOPE)) suspects += it }
            stackPackage(line)?.let { if (!it.startsWith(SHIPPED_SCOPE)) suspects += it }
            DIAGNOSTICS.find(line)?.let { diagnostics = it.groupValues[1] }
        }
        return RunFailure(
            kind = kind,
            exitCode = exitCode,
            at = wallClock,
            safeMode = safeMode,
            summary = fatal?.let(::summarize)
                ?: (if (kind == FailureKind.LAUNCH_FAILED) launch else tail.lastOrNull { NO_SPACE.containsMatchIn(it) })
                    ?.let(::summarize),
            requiredRows = required.toList(),
            suspects = suspects.toList(),
            diagnostics = diagnostics,
            upSeconds = readyAt?.let { ((now - it).coerceAtLeast(0)) / 1000 },
        )
    }

    /** `…/profiles/web/node_modules/[.pnpm/x@1/node_modules/]<pkg>/…` → `<pkg>` (scoped names kept whole). */
    fun stackPackage(line: String): String? {
        val start = line.indexOf(WEB_MODULES)
        if (start < 0) return null
        var rest = line.substring(start + WEB_MODULES.length).takeWhile { !it.isWhitespace() && it != ')' }
        val nested = rest.lastIndexOf("node_modules/")
        if (nested >= 0) rest = rest.substring(nested + "node_modules/".length)
        val parts = rest.split('/')
        val name = if (parts[0].startsWith("@") && parts.size > 1) parts[0] + "/" + parts[1] else parts[0]
        return name.takeIf { it.isNotEmpty() && !it.startsWith(".") && !it.contains(':') }
    }

    private fun summarize(line: String): String {
        var text = LogRedactor.redact(line.trim())
        text = text.removePrefix("dsh: ")
        text = text.replaceFirst(Regex("^[A-Za-z]*Error: dsh: "), "")
        return if (text.length > SUMMARY_MAX) text.take(SUMMARY_MAX - 1) + "…" else text
    }
}
