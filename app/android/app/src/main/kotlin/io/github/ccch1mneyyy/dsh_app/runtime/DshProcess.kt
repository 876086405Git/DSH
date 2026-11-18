package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.os.Process as AndroidProcess
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.github.ccch1mneyyy.dsh_app.phone.PhoneGuest
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Runs `dsh web` through proot, the optional direct glibc planner or the optional
 * tawcroot launcher, using the same composed manifest configuration. Reports ready
 * after the token and socket.
 */
class DshProcess(
    private val context: Context,
    private val manifest: RuntimeManifest,
    private val rootfs: File,
    private val listener: Listener,
) {
    interface Listener {
        /** Raw display line and a separate copy with streamed private-key bodies removed. */
        fun onLog(line: String, stream: String, storageLine: String = line)
        fun onReady(source: DshProcess, baseUrl: String, token: String)
        fun onExit(source: DshProcess, code: Int, expected: Boolean)
        /** Called under the process monitor: enqueue owner updates without waiting for its lock. */
        fun onStartupFailure(source: DshProcess)
        /** The start is busy turning PRoot's fake hard links into real files (true), or done (false). */
        fun onTidying(active: Boolean) {}
    }

    @Volatile private var process: Process? = null
    @Volatile private var stopping = false
    @Volatile private var expectedExit = false
    @Volatile private var readyReported = false
    private val startupSignal = CountDownLatch(1)
    @Volatile private var waiter: Thread? = null
    @Volatile private var stopper: Thread? = null
    // Share captured identities across launcher replacement within this app
    // process. Both capture and cleanup use the shared state's monitor.
    private val cleanupState by lazy {
        RuntimeProcessOwnership.cleanupState(rootfs.canonicalPath, AndroidProcess.myUid())
    }
    private val cleanupKnown get() = cleanupState.known
    var port: Int = DEFAULT_PORT
        private set

    @Volatile var startupError: String? = null
        private set

    @Volatile var startupTokenTimedOut: Boolean = false
        private set

    /** The launch command got the phone-control overlay (see [PhoneGuest.launchArg]). */
    var phoneMounted: Boolean = false
        private set

    /** Actual method for this process, fixed before it can be spawned. Safe mode stays proot. */
    var direct: Boolean = false
        private set

    /** This process runs under tawcroot ([TawcrootLaunch]); fixed before it can be spawned. */
    var tawc: Boolean = false
        private set

    val launchDiagnostics = LaunchDiagnostics()
    val executionMode: String? get() = launchDiagnostics.currentMode(process?.isAlive == true)

    var directFallbackReason: String? = null
        private set

    /**
     * [binds] are extra proot `-b host:guest` mounts, inserted before the guest command.
     * [safe] boots the rescue profile instead of `web` (see [SafeMode.profileArg]).
     */
    fun start(guestEnv: Map<String, String>, binds: List<String> = emptyList(), safe: Boolean = false, phone: Boolean = false, directEngine: Boolean = false, directFailed: Boolean = false, searchOverlay: Boolean = false, authOverlay: Boolean = false, speechOverlay: Boolean = false, tawcEngine: Boolean = false, tawcFailed: Boolean = false, onLaunchMethod: ((Boolean) -> Unit)? = null) {
        check(process == null) { "already started" }
        // tawcroot wins over Direct when both are on; like Direct it needs PRoot's fake hard links gone.
        val tawcWanted = tawcEngine && !safe
        val tawcMissing = if (tawcWanted) TawcrootLaunch.unavailable(context.applicationInfo.nativeLibraryDir, android.os.Build.VERSION.SDK_INT) else null
        val tawcReady = tawcWanted && !tawcFailed && tawcMissing == null
        var selection = if (tawcReady) DirectLaunch.select(rootfs, requested = true, safe = false)
            else DirectLaunch.select(rootfs, directEngine, safe, directFailed)
        // Only PRoot's fake hard links stand in the way: tidy them once no runtime process is left.
        val tidy = selection.fallbackReason == DirectLaunch.INCOMPATIBLE
        val cleanup = reapStrays(allowObservationGap = true)
        if (tidy && cleanup.complete) selection = tidyLinks(binds)
        tawc = tawcReady && selection.direct
        direct = selection.direct && !tawcReady
        directFallbackReason = selection.fallbackReason ?: when {
            tawcWanted && tawcFailed -> TawcrootLaunch.FAILED
            tawcMissing != null -> tawcMissing
            (directEngine || tawcEngine) && safe -> "safeRecovery"
            else -> null
        }
        launchDiagnostics.selected(if (tawc) "tawcroot" else if (direct) "direct" else "proot", directFallbackReason)
        check(!cleanup.ownedRemaining) { "runtime cleanup incomplete; stop the engine and retry" }
        if (!cleanup.complete) listener.onLog("[dsh-app] starting with incomplete process observation; no captured runtime identities remain", "system")
        val pidFile = File(rootfs, "tmp/dsh-web.pid")
        pidFile.delete() // also removes a stale/dangling symlink; never reuse a previous run's PID
        check(!java.nio.file.Files.exists(pidFile.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)) { "cannot remove stale runtime pid file" }
        port = pickPort()
        val tmp = File(context.cacheDir, "proot-tmp").apply { mkdirs() }
        if (cleanup.canPruneTemp) {
            val reclaimed = ProotTempFiles.prune(tmp) { pid -> processReader.uid(pid) == null }
            if (reclaimed.removed > 0) listener.onLog("[dsh-app] reclaimed ${reclaimed.removed} stale proot temporary directories", "system")
            if (reclaimed.incomplete) listener.onLog("[dsh-app] proot temporary cleanup incomplete; retained entries for a later start", "system")
        }
        val vars = mapOf(
            "{NATIVE_LIB_DIR}" to context.applicationInfo.nativeLibraryDir,
            "{ROOTFS}" to rootfs.canonicalPath,
            "{TMP}" to tmp.absolutePath,
            "{FILES_DIR}" to context.filesDir.absolutePath,
            "{PORT}" to port.toString(),
        )
        fun expand(s: String) = vars.entries.fold(s) { acc, (k, v) -> acc.replace(k, v) }

        val argv = ArrayList<String>()
        val sameBind = DirectLaunch.samePathBind(rootfs)
        val launchArgv = DirectLaunch.prootArguments(rootfs, manifest.launchArgv, direct)
        val allBinds = binds.filterNot { expand(it) == sameBind }.distinct()
        // PRoot's Node resolves through glibc, which fails A with a refused AAAA (#152): add Direct's resolver.
        val effectiveGuestEnv = guestEnv + ("DSH_GO_RUNTIME_ROOT" to rootfs.canonicalPath) +
            listOfNotNull(if (direct) null else "NODE_OPTIONS" to DirectLaunch.prootNodeOptions(guestEnv["NODE_OPTIONS"]))
        var guestEnvPlaced = false
        check(manifest.launchArgv.isNotEmpty()) { "runtime manifest has no launch.argv" }
        var bindsPlaced = false
        var profileSelected = false
        // Only overlays successfully prepared for this launch; cleanup may leave an old file behind.
        // Also require the file in place (a missing --patch file stops DSH).
        var searchPending = !safe && searchOverlay && SessionSearchGuest.file(rootfs).isFile
        // Subscription sign-in: the same rule for the auth bridge overlay.
        var authPending = !safe && authOverlay && AppAuthGuest.file(rootfs).isFile
        // On-device voice input: the recognizer's phone settings, same rule.
        var speechPending = !safe && speechOverlay && SpeechGuest.file(rootfs).isFile
        for (arg in launchArgv) {
            if (!bindsPlaced && arg == "/usr/bin/env") {
                allBinds.forEach { argv += "-b"; argv += it }
                bindsPlaced = true
            }
            if (arg == GUEST_ENV) {
                effectiveGuestEnv.forEach { (k, v) -> argv += "$k=$v" }
                guestEnvPlaced = true
            } else {
                val selected = SafeMode.profileArg(arg, safe)
                if (selected != null) profileSelected = true
                // Phone control: add its --patch overlay to `dsh web` (never in safe mode).
                val withPhone = if (phone && !safe && !phoneMounted) PhoneGuest.launchArg(selected ?: arg) else null
                if (withPhone != null) phoneMounted = true
                val withSearch = if (searchPending) SessionSearchGuest.launchArg(withPhone ?: selected ?: arg) else null
                if (withSearch != null) searchPending = false
                val withAuth = if (authPending) AppAuthGuest.launchArg(withSearch ?: withPhone ?: selected ?: arg) else null
                if (withAuth != null) authPending = false
                val withSpeech = if (speechPending) SpeechGuest.launchArg(withAuth ?: withSearch ?: withPhone ?: selected ?: arg) else null
                if (withSpeech != null) speechPending = false
                argv += expand(withSpeech ?: withAuth ?: withSearch ?: withPhone ?: selected ?: arg)
            }
        }
        check(!safe || profileSelected) { "safe mode: this runtime's launch command has no `dsh web` to replace" }

        val builder = ProcessBuilder(argv).directory(context.filesDir)
        val env = builder.environment()
        env.clear()
        env["PATH"] = "/system/bin:/system/xbin"
        env["HOME"] = context.filesDir.absolutePath
        env["TMPDIR"] = tmp.absolutePath
        env["ANDROID_ROOT"] = System.getenv("ANDROID_ROOT") ?: "/system"
        env["ANDROID_DATA"] = System.getenv("ANDROID_DATA") ?: "/data"
        env["PROOT_TMP_DIR"] = tmp.absolutePath
        manifest.launchEnv.forEach { (k, v) -> env[k] = expand(v) }
        if (!guestEnvPlaced) env.putAll(effectiveGuestEnv)
        val tawcPlan = if (!tawc) null else try {
            TawcrootLaunch.prepare(rootfs.canonicalPath, context.applicationInfo.nativeLibraryDir, argv, env.toMap())
        } catch (e: TawcrootLaunch.Unsupported) {
            listener.onLog("[dsh-app] tawcroot fallback: ${e.message}; compatible launch this time", "system")
            tawc = false
            directFallbackReason = TawcrootLaunch.UNSUPPORTED
            launchDiagnostics.selected("proot", directFallbackReason)
            null
        }
        // tawcroot's stored hard links are only readable under tawcroot: make them files first.
        if (!tawc && TawcrootLinks.pending(rootfs)) {
            check(cleanup.complete) { "runtime cleanup incomplete; stop the engine and retry" }
            untangleTawcroot()
        }
        if (direct) {
            val plan = DirectLaunch.prepare(rootfs, manifest.abi, argv, env.toMap())
            builder.command(plan.argv).directory(plan.cwd)
            env.clear()
            env.putAll(plan.environment)
        }
        if (tawcPlan != null) {
            TawcrootLaunch.writeDevView(tawcPlan.devView)
            builder.command(tawcPlan.argv).directory(File(tawcPlan.cwd))
            env.clear()
            env.putAll(tawcPlan.environment)
        }

        readyReported = false
        if (directFallbackReason == DirectLaunch.INCOMPATIBLE) listener.onLog("[dsh-app] direct fallback: proot hard-link backing files need compatible launch; user preference and data retained", "system")
        if (directFallbackReason == DirectLaunch.FAILED) listener.onLog("[dsh-app] direct fallback: direct launch failed before with this runtime; turn Direct on again to retry", "system")
        if (directFallbackReason == TawcrootLaunch.FAILED) listener.onLog("[dsh-app] tawcroot fallback: tawcroot failed to start before with this runtime; turn tawcroot on again to retry", "system")
        listener.onLog("[dsh-app] launch method: ${if (tawc) "tawcroot" else if (direct) "direct-glibc" else "proot"}${if ((directEngine || tawcEngine) && safe) " (safe recovery)" else ""}", "system")
        listener.onLog("[dsh-app] launching ${builder.command().joinToString(" ") { redact(it) }}", "system")
        // stop() came in while this was being prepared: don't launch at all.
        if (stopping) {
            listener.onExit(this, 0, true)
            return
        }
        onLaunchMethod?.invoke(direct)
        val p = builder.start()
        process = p
        launchDiagnostics.spawned()
        val out = pump(p.inputStream.bufferedReader(), "stdout")
        val err = pump(p.errorStream.bufferedReader(), "stderr")
        waiter = thread(name = "dsh-wait", isDaemon = true) {
            val code = try { p.waitFor() } catch (_: InterruptedException) { -1 }
            startupSignal.countDown()
            // The fatal message is usually the last output: let the pumps drain it before reporting.
            try {
                out.join(2000)
                err.join(2000)
            } catch (_: InterruptedException) {
            }
            // Report after a running stop() has finished: its killStrays() must not hit the next launch.
            val stopThread = synchronized(this) {
                process = null
                stopper
            }
            stopThread?.join()
            // An unexpected parent exit can leave tracees behind too. Keep the
            // controller's ownership until this UID sweep has finished.
            if (stopThread == null) killStrays()
            listener.onExit(this, code, expectedExit)
        }
        // The port deadline starts only after a token. A stuck loader/Node can emit nothing.
        thread(name = "dsh-start-deadline", isDaemon = true) {
            if (startupSignal.await(TOKEN_TIMEOUT_MS, TimeUnit.MILLISECONDS)) return@thread
            synchronized(this) {
                // Token detection and stop share this lock; a late deadline cannot retire either.
                if (process === p && p.isAlive && !readyReported && !stopping) {
                    startupTokenTimedOut = true
                    failStart("no startup token received within ${TOKEN_TIMEOUT_MS / 1000}s")
                }
            }
        }
        if (stopping) stop()
    }

    /**
     * Direct was asked for and PRoot's fake hard links are the only obstacle: make
     * them real files ([L2sMigration]). Short of room or on an error this start stays
     * on PRoot with every name intact, and the next start carries on from there.
     */
    private fun tidyLinks(binds: List<String>): DirectLaunch.Selection {
        val started = System.nanoTime()
        // Every bind a PRoot launch may have used: this one's, plus the rootfs alias of earlier ones.
        val guestBinds = L2sMigration.bindTargets(
            DirectLaunch.prootArguments(rootfs, manifest.launchArgv, direct = false),
            binds + DirectLaunch.samePathBind(rootfs),
        )
        val result = try {
            L2sMigration(rootfs, ::syncFilesystems, guestBinds = guestBinds).run(onSlow = { listener.onTidying(true) })
        } catch (e: Exception) {
            listener.onLog("[dsh-app] direct fallback: tidying PRoot links stopped (${e.javaClass.simpleName}: ${e.message}); compatible launch this time, the next start continues", "system")
            return DirectLaunch.Selection(false, DirectLaunch.MIGRATION_FAILED)
        } finally {
            listener.onTidying(false)
        }
        if (result is L2sMigration.Result.NotEnoughSpace) {
            listener.onLog("[dsh-app] direct fallback: tidying PRoot links needs ${result.need shr 20} MB plus ${L2sMigration.MARGIN shr 20} MB spare, ${result.free shr 20} MB free; compatible launch this time", "system")
            return DirectLaunch.Selection(false, DirectLaunch.NOT_ENOUGH_SPACE)
        }
        listener.onLog("[dsh-app] direct: moved ${(result as L2sMigration.Result.Done).links} PRoot links to real files in ${(System.nanoTime() - started) / 1_000_000} ms", "system")
        val reason = DirectLaunch.compatibilityReason(rootfs)
        return DirectLaunch.Selection(reason == null, reason)
    }

    /**
     * PRoot or Direct is next and tawcroot left emulated hard links: turn them into
     * files ([TawcrootLinks]). Without room this start fails with what to do; nothing
     * is lost, tawcroot can still read every name.
     */
    private fun untangleTawcroot() {
        val started = System.nanoTime()
        val result = try {
            TawcrootLinks(rootfs, ::syncFilesystems).run(onSlow = { listener.onTidying(true) })
        } finally {
            listener.onTidying(false)
        }
        if (result is TawcrootLinks.Result.NotEnoughSpace) {
            throw IllegalStateException("files from the tawcroot launch need ${result.need shr 20} MB plus " +
                "${L2sMigration.MARGIN shr 20} MB spare to switch back, ${result.free shr 20} MB free; free up space or turn tawcroot on again")
        }
        listener.onLog("[dsh-app] tawcroot: turned ${(result as TawcrootLinks.Result.Done).names} linked names into files in ${(System.nanoTime() - started) / 1_000_000} ms", "system")
    }

    /** Waits for cleanup and exit reporting; zero waits until completion. */
    fun awaitExit(millis: Long = 0): Boolean {
        // The waiter joins the stopper before reporting exit. Startup can fail
        // after spawning but before allocating it, so await the stopper then.
        val ending = waiter ?: stopper
        ending?.join(millis)
        return ending?.isAlive != true
    }

    /** Preserve a startup failure through cleanup and the service's later STOP. */
    @Synchronized fun failStart(message: String) {
        if (stopping) {
            // STOP may have preceded spawn, then setup failed before start's final stop().
            // Preserve its expected-exit/error facts while cleaning any process now present.
            stop(expected = false)
            return
        }
        startupError = message
        listener.onLog("[dsh-app] start failed: $message", "system")
        listener.onStartupFailure(this)
        stop(expected = false)
    }

    /**
     * proot ignores SIGTERM, so stop DSH itself first (pid file written by the launch
     * command), then SIGQUIT proot, which kills every remaining tracee.
     */
    @Synchronized fun stop(expected: Boolean = true) {
        stopping = true
        startupSignal.countDown()
        if (expected) expectedExit = true
        if (stopper != null) return
        val p = process ?: return
        stopper = thread(name = "dsh-stop", isDaemon = true) {
            try {
                val node = if (p.isAlive) guestRecord() else null
                val proot = if (direct || tawc) null else node?.let { child -> processSnapshot().records.firstOrNull { it.pid == child.parent && it.proot } }
                if (node != null) signalOwned(node, OsConstants.SIGTERM)
                else if ((direct || tawc) && p.isAlive) p.destroy() // loader/preload may fail before writing its pid file
                if (!waitExit(p, 5000) && proot != null) signalOwned(proot, OsConstants.SIGQUIT)
                // Tawcroot needs no extra QUIT grace; retain PRoot and Direct's existing wait.
                if (!tawc) waitExit(p, 2000)
            } finally {
                try {
                    if (p.isAlive) p.destroyForcibly()
                } finally {
                    // Reap tracees before waiting: an OEM Process.waitFor may not
                    // return until they exit. The waiter still retains this owner.
                    killStrays()
                    p.waitFor()
                }
            }
        }
    }

    private fun waitExit(p: Process, millis: Long): Boolean {
        val deadline = System.nanoTime() + millis * 1_000_000L
        while (p.isAlive && System.nanoTime() < deadline) Thread.sleep(100)
        return !p.isAlive
    }

    /** Guest `dsh web` identity, retained through the final pre-signal PID-reuse check. */
    @Synchronized private fun guestRecord(): RuntimeProcessRecord? = synchronized(cleanupState) {
        captureGuestRecord()
    }

    private fun captureGuestRecord(): RuntimeProcessRecord? {
        return try {
            val pid = File(rootfs, "tmp/dsh-web.pid").takeIf { it.isFile }?.readText()?.trim()?.toIntOrNull() ?: return null
            val records = processSnapshot().records
            val owned = RuntimeProcessOwnership.owned(records, setOf(rootfs.absolutePath, rootfs.canonicalPath), AndroidProcess.myPid())
            owned.forEach { cleanupKnown[it.pid] = it.started }
            val record = owned.firstOrNull { it.pid == pid } ?: return null
            if (record.argv.any { it.contains("/opt/node") || it.contains("dsh") }) record else null
        } catch (_: Exception) {
            null
        }
    }

    private fun signalOwned(record: RuntimeProcessRecord, value: Int) = runCatching {
        val current = RuntimeProcessOwnership.stat(File("/proc/${record.pid}/stat").readText())
        if (current?.second == record.started && Os.stat("/proc/${record.pid}").st_uid == AndroidProcess.myUid()) {
            Os.kill(record.pid, value)
        }
    }

    private fun pump(reader: java.io.BufferedReader, stream: String) = thread(name = "dsh-$stream", isDaemon = true) {
        val redactor = LogRedactor()
        try {
            reader.useLines { lines ->
                lines.forEach { line ->
                    listener.onLog(line, stream, redactor.line(line))
                    if (!readyReported) detectToken(line)
                }
            }
        } catch (_: Exception) {
        }
    }

    @Synchronized private fun detectToken(line: String) {
        if (readyReported || stopping) return
        val match = TOKEN_URL.find(line) ?: return
        val url = match.value
        val token = TOKEN_PARAM.find(url)?.groupValues?.get(1) ?: return
        readyReported = true
        startupSignal.countDown()
        val base = "http://127.0.0.1:$port"
        thread(name = "dsh-ready", isDaemon = true) {
            val deadline = System.currentTimeMillis() + 90_000
            while (System.currentTimeMillis() < deadline && !stopping && process?.isAlive == true) {
                if (canConnect(port)) {
                    listener.onReady(this, base, token)
                    return@thread
                }
                Thread.sleep(250)
            }
            if (!stopping && process?.isAlive == true) {
                failStart("token seen but port $port never accepted connections")
            }
        }
    }

    /** Reads only this app's uid. Environment values are used for ownership, never logged. */
    private val processReader = object : RuntimeProcessReader {
        override fun pids(): List<Int> = (File("/proc").listFiles() ?: throw IOException("cannot enumerate /proc"))
            .mapNotNull { it.name.toIntOrNull() }
        override fun uid(pid: Int): Int? = try {
            Os.stat("/proc/$pid").st_uid
        } catch (error: ErrnoException) {
            if (error.errno == OsConstants.ENOENT || error.errno == OsConstants.ESRCH) null else throw error
        } catch (_: NoSuchFileException) { null }
        private fun text(pid: Int, name: String): String = Files.readAllBytes(File("/proc/$pid/$name").toPath()).toString(Charsets.UTF_8)
        override fun stat(pid: Int): String = text(pid, "stat")
        override fun command(pid: Int): String = text(pid, "cmdline")
        override fun environment(pid: Int): String = text(pid, "environ")
        override fun cwd(pid: Int): String = Os.readlink("/proc/$pid/cwd")
    }

    private fun processSnapshot(known: Set<Int> = emptySet()): RuntimeProcessSnapshot =
        RuntimeProcessOwnership.scan(processReader, AndroidProcess.myUid(), AndroidProcess.myPid(), known)

    private fun remember(snapshot: RuntimeProcessSnapshot) {
        snapshot.retired.forEach { cleanupKnown.remove(it) }
        for (record in snapshot.records) {
            if (cleanupKnown[record.pid]?.let { it != record.started } == true) cleanupKnown.remove(record.pid)
        }
    }

    /** Reap a captured process tree before releasing #17 ownership to another launch. */
    @Synchronized fun killStrays(): Boolean = reapStrays().complete

    internal data class CleanupResult(val complete: Boolean, val ownedRemaining: Boolean, val canPruneTemp: Boolean = false)

    /** Unknown ambient processes are not proof of ownership. Startup may
     * continue after reaping every captured identity, while
     * killStrays itself still reports the observation as incomplete. */
    @Synchronized internal fun reapStrays(allowObservationGap: Boolean = false): CleanupResult = synchronized(cleanupState) {
        reapStraysLocked(allowObservationGap)
    }

    private fun reapStraysLocked(allowObservationGap: Boolean): CleanupResult {
        val myPid = AndroidProcess.myPid()
        val roots = setOf(rootfs.absolutePath, rootfs.canonicalPath)
        val deadline = System.nanoTime() + 2_000_000_000L
        var first = true
        while (true) {
            // A persisted bare PID can be reused by a hidden, unrelated process.
            // Only captured identities supplement the current /proc enumeration.
            val snapshot = processSnapshot(cleanupKnown.keys)
            remember(snapshot)
            val owned = RuntimeProcessOwnership.owned(snapshot.records, roots, myPid, cleanupKnown)
            owned.forEach { cleanupKnown[it.pid] = it.started }
            val ownedRemaining = owned.isNotEmpty() || cleanupKnown.isNotEmpty()
            if (!ownedRemaining && snapshot.observed) {
                // This cache is shared across rootfs instances. Another engine may still use its glue.
                val temp = File(context.cacheDir, "proot-tmp").absolutePath
                val idle = snapshot.records.none { it.proot || it.marker != null || RuntimeProcessOwnership.within(it.cwd, temp) }
                return CleanupResult(true, false, canPruneTemp = idle)
            }
            owned.filter { it.proot }.forEach { signalOwned(it, if (first) OsConstants.SIGQUIT else OsConstants.SIGKILL) }
            owned.filterNot { it.proot }.forEach { signalOwned(it, OsConstants.SIGKILL) }
            first = false
            if ((!ownedRemaining && allowObservationGap) || System.nanoTime() >= deadline) {
                listener.onLog("[dsh-app] cleanup incomplete: ${owned.size} owned process(es) remain; " +
                    "${snapshot.uncertain.size} process observation(s) unavailable" +
                    if (snapshot.enumerationFailed) "; /proc enumeration unavailable" else "", "system")
                return CleanupResult(false, ownedRemaining)
            }
            Thread.sleep(25)
        }
    }

    private fun redact(arg: String): String {
        val eq = arg.indexOf('=')
        if (eq <= 0) return arg
        val key = arg.substring(0, eq)
        return if (SECRET_KEY.containsMatchIn(key)) "$key=***" else arg
    }

    companion object {
        const val DEFAULT_PORT = 3080
        const val GUEST_ENV = "{GUEST_ENV}"
        // Bootstrap budget (not a device measurement); token-to-port retains its own 90 seconds.
        private const val TOKEN_TIMEOUT_MS = 180_000L
        private val TOKEN_URL = Regex("""https?://[^\s'"]*[?&#]token=[A-Za-z0-9._~%-]+""")
        private val TOKEN_PARAM = Regex("""[?&#]token=([A-Za-z0-9._~%-]+)""")
        private val SECRET_KEY = Regex("(?i)(key|token|secret|password)")

        fun canConnect(port: Int): Boolean = try {
            Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 500); true }
        } catch (_: Exception) {
            false
        }

        fun pickPort(): Int {
            for (candidate in DEFAULT_PORT..DEFAULT_PORT + 20) {
                try {
                    ServerSocket(candidate, 1, InetAddress.getByName("127.0.0.1")).close()
                    return candidate
                } catch (_: Exception) {
                }
            }
            return ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
        }
    }
}

/** One sync(2): finished copies and renames are on disk before anything depends on them. */
internal fun syncFilesystems() {
    val sync = ProcessBuilder("/system/bin/sync").redirectErrorStream(true).start()
    sync.inputStream.use { it.readBytes() }
    val code = sync.waitFor()
    if (code != 0) throw IOException("sync exited with $code")
}
