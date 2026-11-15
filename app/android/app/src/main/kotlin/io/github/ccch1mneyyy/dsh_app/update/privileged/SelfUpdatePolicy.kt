package io.github.ccch1mneyyy.dsh_app.update.privileged

import io.github.ccch1mneyyy.dsh_app.BuildConfig

import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

class SelfUpdateException(val code: String) : Exception(code)

internal data class SelfUpdateIdentity(
    val packageName: String,
    val versionCode: Long,
    val versionName: String?,
    val signers: Set<String>,
    val signerHistory: Set<String> = signers,
)

internal data class SelfUpdateReceipt(
    val status: String,
    val errorCode: String? = null,
    val submitted: Boolean = false,
    val outcomeUnknown: Boolean = false,
) {
    fun toMap(): Map<String, Any?> = mapOf("status" to status, "errorCode" to errorCode,
        "submitted" to submitted, "outcomeUnknown" to outcomeUnknown)
}

/** This is an installer capability, not a shell command API. */
internal object SelfUpdatePolicy {
    val PACKAGE = BuildConfig.APPLICATION_ID
    const val REVISION = "dsh-self-update-1"
    const val TAG = "dsh_self_update_v1"
    const val MAX_APK_BYTES = 2L * 1024 * 1024 * 1024
    const val INSTALL_TIMEOUT_MS = 180_000L
    const val PREPARED_TTL_MS = 300_000L
    const val MAX_OUTPUT_BYTES = 16 * 1024
    private val digestPattern = Regex("[0-9a-fA-F]{64}")

    fun digest(value: String): String {
        if (!value.matches(digestPattern)) throw SelfUpdateException("invalidArguments")
        return value.lowercase(java.util.Locale.ROOT)
    }

    fun requireIdentity(uid: Int) {
        if (uid != 2000) throw SelfUpdateException("unsupportedIdentity")
    }

    fun sameSigner(candidate: SelfUpdateIdentity, installed: SelfUpdateIdentity): Boolean =
        candidate.signers.isNotEmpty() && installed.signers.isNotEmpty() && candidate.signers == installed.signers

    fun validate(candidate: SelfUpdateIdentity, installed: SelfUpdateIdentity, expectedVersion: Long) {
        if (candidate.packageName != PACKAGE || installed.packageName != PACKAGE)
            throw SelfUpdateException("packageMismatch")
        if (!sameSigner(candidate, installed)) throw SelfUpdateException("signatureMismatch")
        if (candidate.versionCode != expectedVersion) throw SelfUpdateException("versionMismatch")
        if (candidate.versionCode <= installed.versionCode) throw SelfUpdateException("notNewer")
    }

    fun installArgv(userId: Int, size: Long): List<String> {
        if (userId !in 0..21474 || size !in 1..MAX_APK_BYTES) throw SelfUpdateException("invalidArguments")
        return listOf("/system/bin/cmd", "package", "install", "-r", "--user", userId.toString(), "-S", size.toString(), "-")
    }

    fun adbInstallService(userId: Int, size: Long): String =
        "exec:" + installArgv(userId, size).let { listOf("cmd") + it.drop(1) }.joinToString(" ")

    fun inputFile(path: String, updates: File): File {
        val root = updates.canonicalFile
        val file = File(path).canonicalFile
        if (file.parentFile != root || file.extension.lowercase(java.util.Locale.ROOT) != "apk")
            throw SelfUpdateException("invalidPath")
        if (!file.isFile) throw SelfUpdateException("fileMissing")
        if (file.length() !in 1..MAX_APK_BYTES) throw SelfUpdateException("sizeMismatch")
        return file
    }

    fun hash(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            if (n > 0) digest.update(buffer, 0, n)
        }
        return hex(digest.digest())
    }

    /** Copies exactly N bytes, checking for both truncation and extra bytes. */
    fun copyVerified(input: InputStream, output: OutputStream, size: Long, expectedHash: String): String {
        if (size !in 1..MAX_APK_BYTES) throw SelfUpdateException("sizeMismatch")
        val expected = digest(expectedHash)
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (total < size) {
            val n = input.read(buffer, 0, minOf(buffer.size.toLong(), size - total).toInt())
            if (n < 0) throw SelfUpdateException("sizeMismatch")
            if (n == 0) continue
            total += n
            output.write(buffer, 0, n)
            digest.update(buffer, 0, n)
        }
        if (input.read() != -1) throw SelfUpdateException("sizeMismatch")
        val actual = hex(digest.digest())
        if (actual != expected) throw SelfUpdateException("hashMismatch")
        return actual
    }

    fun interpretOutput(output: String, complete: Boolean, exitCode: Int? = null): SelfUpdateReceipt {
        if (!complete) return unknown()
        val text = output.trim()
        if (text == "Success" && (exitCode == null || exitCode == 0))
            return SelfUpdateReceipt("success", submitted = true)
        // Only a complete, explicit system rejection is a known failure.
        if (text.startsWith("Failure [") && text.endsWith("]")) {
            val code = when {
                "INSTALL_FAILED_INSUFFICIENT_STORAGE" in text -> "storage"
                "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in text -> "signatureMismatch"
                "INSTALL_FAILED_VERSION_DOWNGRADE" in text -> "notNewer"
                "INSTALL_FAILED_USER_RESTRICTED" in text || "INSTALL_FAILED_VERIFICATION_FAILURE" in text -> "systemBlocked"
                "INSTALL_FAILED_NO_MATCHING_ABIS" in text || "INSTALL_FAILED_OLDER_SDK" in text -> "unsupportedAbi"
                else -> "systemRejected"
            }
            val status = when (code) {
                "storage" -> "storage"
                "signatureMismatch", "notNewer", "unsupportedAbi" -> "incompatible"
                "systemBlocked" -> "blocked"
                else -> "failure"
            }
            return SelfUpdateReceipt(status, code, submitted = true)
        }
        return unknown()
    }

    fun unknown() = SelfUpdateReceipt("unknown", "outcomeUnknown", submitted = true, outcomeUnknown = true)
    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
}
