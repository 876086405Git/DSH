package io.github.ccch1mneyyy.dsh_app.update.privileged

import android.content.Context
import android.os.Build
import io.github.ccch1mneyyy.dsh_app.phone.background.AdbKeyStore
import io.github.muntashirakon.adb.AdbStream
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.android.AdbMdns
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.InetAddress
import java.net.NetworkInterface
import java.security.PrivateKey
import java.security.cert.Certificate
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Independent connection, shared already-paired private identity; never pairs or launches app_process. */
internal class SelfUpdateAdb private constructor(private val context: Context) : SelfUpdateTransport {
    private val keys = AdbKeyStore(context)
    private val manager = object : AbsAdbConnectionManager() {
        init { setApi(Build.VERSION.SDK_INT); setTimeout(8, TimeUnit.SECONDS) }
        override fun getPrivateKey(): PrivateKey = keys.privateKey()
        override fun getCertificate(): Certificate = keys.certificate()
        override fun getDeviceName(): String = "dsh-app"
    }
    private val closed = AtomicBoolean(false)
    private val worker = Executors.newSingleThreadExecutor { task -> Thread(task, "dsh-update-adb").apply { isDaemon = true } }
    @Volatile private var activeStream: AdbStream? = null
    override var uid: Int = -1
        private set

    override fun verifyIdentity() {
        if (closed.get()) throw SelfUpdateException("transportLost")
        try {
            val actual = timed(5000) {
                val stream = manager.openStream("exec:/system/bin/id -u")
                activeStream = stream
                try {
                    if (closed.get()) throw SelfUpdateException("transportLost")
                    val bytes = ByteArrayOutputStream()
                    val input = stream.openInputStream().buffered()
                    while (true) {
                        val b = input.read()
                        if (b < 0 || b == '\n'.code) break
                        if (bytes.size() >= 64 || b > 127) throw SelfUpdateException("identityChanged")
                        bytes.write(b)
                    }
                    bytes.toString("US-ASCII").trim().toIntOrNull() ?: throw SelfUpdateException("identityChanged")
                } finally { runCatching { stream.close() }; activeStream = null }
            }
            SelfUpdatePolicy.requireIdentity(actual)
            if (uid != -1 && uid != actual) throw SelfUpdateException("identityChanged")
            uid = actual
        } catch (error: Exception) {
            if (error is InterruptedException) Thread.currentThread().interrupt()
            val cause = error.cause
            throw if (error is SelfUpdateException) error else if (cause is SelfUpdateException) cause
                else SelfUpdateException("connectFailed")
        }
    }

    override fun install(prepared: PreparedSelfUpdate, userId: Int, requestId: String): SelfUpdateReceipt {
        // The controller has persisted before this call. Opening exec can already create a system session.
        return try {
            timed(SelfUpdatePolicy.INSTALL_TIMEOUT_MS + 2000) {
                val stream = manager.openStream(SelfUpdatePolicy.adbInstallService(userId, prepared.snapshot.size))
                activeStream = stream
                try {
                    if (closed.get()) throw SelfUpdateException("transportLost")
                    SelfUpdateStreams.exchange(prepared.snapshot.input(), prepared.snapshot.size, prepared.sha256,
                        stream.openInputStream(), stream.openOutputStream(), endAtAdbResultLine = true,
                        close = { stream.close() })
                } finally { runCatching { stream.close() }; activeStream = null }
            }
        } catch (error: Exception) {
            if (error is InterruptedException) Thread.currentThread().interrupt()
            SelfUpdatePolicy.unknown()
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        worker.shutdownNow()
        Thread({
            runCatching { activeStream?.close() }
            runCatching { manager.disconnect() }
        }, "dsh-update-adb-close").apply { isDaemon = true; start() }
    }

    private fun <T> timed(timeoutMs: Long, action: () -> T): T {
        if (closed.get()) throw SelfUpdateException("transportLost")
        val future = worker.submit<T> { action() }
        return try { future.get(timeoutMs, TimeUnit.MILLISECONDS) } catch (error: Exception) {
            future.cancel(true)
            close()
            if (error is InterruptedException) Thread.currentThread().interrupt()
            throw error
        }
    }

    private fun discoverPort(): Int? {
        val guard = Object()
        var port: Int? = null
        val accepting = AtomicBoolean(true)
        val discovery = AdbMdns(context, AdbMdns.SERVICE_TYPE_TLS_CONNECT) { address, candidate ->
            if (!accepting.get() || !localAddress(address) || candidate !in 1..65535) return@AdbMdns
            synchronized(guard) { port = candidate; guard.notifyAll() }
        }
        try {
            discovery.start()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
            synchronized(guard) {
                while (port == null && !closed.get()) {
                    val remaining = deadline - System.nanoTime()
                    if (remaining <= 0) break
                    TimeUnit.NANOSECONDS.timedWait(guard, minOf(remaining, TimeUnit.MILLISECONDS.toNanos(100)))
                }
                return port
            }
        } finally {
            accepting.set(false)
            runCatching { discovery.stop() }
        }
    }

    companion object {
        fun connect(context: Context, manualPort: Int?): SelfUpdateAdb {
            val directory = File(context.filesDir, "phone-adb")
            if (!File(directory, "paired").isFile || !File(directory, "adbkey.pk8").isFile || !File(directory, "adbkey.crt").isFile)
                throw SelfUpdateException("adbNotPaired")
            val transport = SelfUpdateAdb(context)
            try {
                val port = manualPort ?: transport.discoverPort() ?: throw SelfUpdateException("connectFailed")
                if (port !in 1..65535) throw SelfUpdateException("invalidArguments")
                // mDNS contributes only a local port; no remote address is ever used as a socket target.
                if (!transport.timed(10000) { transport.manager.connect("127.0.0.1", port) })
                    throw SelfUpdateException("connectFailed")
                transport.verifyIdentity()
                return transport
            } catch (error: Exception) {
                transport.close()
                if (error is InterruptedException) Thread.currentThread().interrupt()
                throw if (error is SelfUpdateException) error else SelfUpdateException("connectFailed")
            }
        }

        internal fun localAddress(address: InetAddress?): Boolean = address != null &&
            (address.isLoopbackAddress || runCatching { NetworkInterface.getByInetAddress(address) != null }.getOrDefault(false))
    }
}
