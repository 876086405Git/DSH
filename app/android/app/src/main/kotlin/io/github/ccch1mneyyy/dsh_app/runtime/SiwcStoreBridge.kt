package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Process
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import java.io.DataInputStream
import java.io.File
import java.io.FileNotFoundException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.KeyStore
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.thread

/** One request per connection, same UID only, with no TCP fallback. See siwc/store.mjs. */
internal class SiwcStoreBridge private constructor(
    private val directory: File,
    private val address: String,
    private val secret: ByteArray,
) : AutoCloseable {
    private val server = LocalServerSocket(address)
    @Volatile private var closed = false
    private var active: LocalSocket? = null

    // DshProcess redacts this environment variable (SECRET_KEY). It contains no OAuth data.
    val endpoint: String get() = address + ":" + secret.joinToString("") { "%02x".format(it) }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        // As in PhoneBridge, shutdown wakes accept/read even if closing alone doesn't.
        runCatching { Os.shutdown(server.fileDescriptor, OsConstants.SHUT_RDWR) }
        runCatching { server.close() }
        active?.let { socket ->
            runCatching { Os.shutdown(socket.fileDescriptor, OsConstants.SHUT_RDWR) }
            runCatching { socket.close() }
        }
    }

    private fun serve() {
        try {
            while (true) {
                val socket = server.accept()
                val admitted = synchronized(this) {
                    if (closed) false else { active = socket; true }
                }
                try {
                    if (!admitted) return
                    handle(socket)
                } catch (_: Exception) {
                    // Invalid/disconnected peer. Never log request payloads or exceptions here.
                } finally {
                    synchronized(this) {
                        runCatching { socket.close() }
                        active = null
                    }
                }
            }
        } catch (_: Exception) {
            // Listener shut down or no longer usable; only SIWC becomes unavailable.
        } finally {
            close()
        }
    }

    // Recheck this launch after acquiring the cross-launch vault lock. An operation
    // already admitted can finish, but always before any new launch accesses the vault.
    // close() only marks retirement and shuts down sockets; it never waits for the vault.
    private inline fun <T> withVault(action: SiwcVault.() -> T): T = synchronized(SiwcVault) {
        check(!closed)
        SiwcVault.action()
    }

    private fun handle(socket: LocalSocket) {
        if (socket.peerCredentials.uid != Process.myUid()) return
        socket.soTimeout = 2_000
        val input = DataInputStream(socket.inputStream)
        val output = socket.outputStream
        val challenge = ByteArray(32).also(input::readFully)
        // The engine verifies this listener before sending a grant, including after an app exit.
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(secret, algorithm)) }
        output.write(mac.doFinal(challenge))
        val result = try {
            when (input.readUnsignedByte()) {
                1 -> withVault { hostId(directory) }
                2 -> withVault { load(directory) }
                3 -> {
                    val length = input.readInt()
                    require(length in 1..MAX_GRANT_BYTES)
                    val grant = ByteArray(length)
                    try {
                        input.readFully(grant)
                        withVault { save(directory, grant) }
                    } finally {
                        grant.fill(0)
                    }
                    ByteArray(0)
                }
                4 -> { withVault { clear(directory) }; ByteArray(0) }
                else -> throw IllegalArgumentException("Invalid SIWC operation")
            }
        } catch (_: Exception) {
            output.write(1)
            return
        }
        try {
            output.write(0)
            output.write(result)
        } finally {
            result.fill(0)
        }
    }

    companion object {
        const val ENV = "DSH_APP_SIWC_SOCKET_SECRET"

        fun start(context: Context): SiwcStoreBridge {
            val address = "dsh-app.siwc." + UUID.randomUUID()
            val secret = ByteArray(32).also(SecureRandom()::nextBytes)
            return SiwcStoreBridge(context.noBackupFilesDir, address, secret).also { bridge ->
                try {
                    thread(name = "dsh-siwc-store", isDaemon = true) { bridge.serve() }
                } catch (error: Exception) {
                    bridge.close()
                    throw error
                }
            }
        }
    }
}

private const val MAX_GRANT_BYTES = 64 * 1024

/** Accessed exclusively through SiwcStoreBridge.withVault. */
private object SiwcVault {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "dsh-app.openai-siwc.v1"
    private const val CIPHER = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128
    private const val VERSION: Byte = 1
    private const val OVERHEAD = 1 + IV_BYTES + TAG_BITS / 8

    private fun grantFile(directory: File) = AtomicFile(File(directory, "openai-siwc.grant"))
    private fun keyStore() = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    fun hostId(directory: File): ByteArray {
        val file = AtomicFile(File(directory, "openai-siwc.host-id"))
        val bytes = read(file, 36) ?: UUID.randomUUID().toString().toByteArray().also { write(file, it) }
        val text = bytes.toString(Charsets.US_ASCII)
        check(UUID.fromString(text).toString() == text)
        return bytes
    }

    fun load(directory: File): ByteArray {
        val envelope = read(grantFile(directory), MAX_GRANT_BYTES + OVERHEAD) ?: return ByteArray(0)
        check(envelope.size > OVERHEAD && envelope[0] == VERSION)
        val key = keyStore().getKey(ALIAS, null) as SecretKey
        return Cipher.getInstance(CIPHER).run {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, envelope, 1, IV_BYTES))
            doFinal(envelope, 1 + IV_BYTES, envelope.size - 1 - IV_BYTES)
        }
    }

    fun save(directory: File, grant: ByteArray) {
        val key = (keyStore().getKey(ALIAS, null) as SecretKey?) ?: KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, KEYSTORE,
        ).run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build())
            generateKey()
        }
        val envelope = Cipher.getInstance(CIPHER).run {
            init(Cipher.ENCRYPT_MODE, key) // AndroidKeyStore supplies a fresh random IV.
            check(iv.size == IV_BYTES)
            byteArrayOf(VERSION) + iv + doFinal(grant)
        }
        write(grantFile(directory), envelope)
    }

    fun clear(directory: File) {
        val file = grantFile(directory)
        // Retire the key too, so stale ciphertext from this grant cannot be decrypted again.
        keyStore().deleteEntry(ALIAS)
        file.delete()
        check(listOf("", ".bak", ".new").all { suffix ->
            Files.notExists(File(file.baseFile.path + suffix).toPath(), LinkOption.NOFOLLOW_LINKS)
        })
    }

    private fun read(file: AtomicFile, max: Int): ByteArray? {
        val input = try {
            file.openRead()
        } catch (e: FileNotFoundException) {
            if (listOf("", ".bak").all { suffix ->
                    Files.notExists(File(file.baseFile.path + suffix).toPath(), LinkOption.NOFOLLOW_LINKS)
                }) return null
            throw e
        }
        return input.use { stream ->
            val size = stream.channel.size()
            check(size in 1..max.toLong())
            ByteArray(size.toInt()).also(DataInputStream(stream)::readFully)
        }
    }

    private fun write(file: AtomicFile, bytes: ByteArray) {
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            stream.fd.sync()
            file.finishWrite(stream)
        } catch (e: Exception) {
            file.failWrite(stream)
            throw e
        }
        // AtomicFile can log rather than throw on a failed rename. Never acknowledge a lost write.
        check(read(file, bytes.size)?.contentEquals(bytes) == true)
    }
}
