package io.github.ccch1mneyyy.dsh_app.share

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import androidx.annotation.RequiresApi
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Shared photos, sized like the composer's own picker (lib/state/attachments.dart
 * `DeviceAttachmentPicker`): phone photos are 12–50 MP, the model gains nothing past ~2.5k on
 * the long side, and the upload shrinks tenfold. Re-encoding also turns HEIC into JPEG and
 * applies the EXIF orientation.
 *
 * PNG / JPEG / WebP that already fit are left as they are (screenshots stay lossless); GIFs
 * are never touched (animation).
 */
internal object ShareImages {
    const val MAX_SIDE = 2560
    private const val QUALITY = 88
    private val keepAsIs = setOf("image/png", "image/jpeg", "image/webp")

    /** Worth decoding: a still image type. */
    fun scalable(mime: String?): Boolean =
        mime != null && mime.startsWith("image/") && mime != "image/gif" && !mime.startsWith("image/svg")

    fun mimeOf(file: File): String = if (file.name.endsWith(".png")) "image/png" else "image/jpeg"

    /** Long side ≤ [MAX_SIDE], aspect kept. */
    fun fit(width: Int, height: Int): Pair<Int, Int> {
        val long = max(width, height)
        if (long <= MAX_SIDE) return width to height
        val scale = MAX_SIDE.toDouble() / long
        return max(1, (width * scale).roundToInt()) to max(1, (height * scale).roundToInt())
    }

    /**
     * A re-encoded copy of the image at [uri] next to [target] (its extension follows the
     * format); null when the original should be copied as it is (it already fits, or this phone
     * can't decode it).
     */
    fun prepare(resolver: ContentResolver, uri: Uri, target: File): File? {
        val bitmap = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) decodeP(resolver, uri) else decodeLegacy(resolver, uri))
            ?: return null
        try {
            val png = bitmap.hasAlpha()
            val name = ShareNames.replaceExtension(target.name, if (png) "png" else "jpg")
            val out = ShareNames.unique(target.parentFile!!, name)
            var complete = false
            try {
                val encoded = out.outputStream().use {
                    bitmap.compress(if (png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, QUALITY, it)
                }
                if (!encoded) return null // The caller falls back to copying the original.
                complete = true
                return out
            } finally {
                if (!complete) out.delete()
            }
        } finally {
            bitmap.recycle()
        }
    }

    /** Thrown from the header callback: this one is sent unchanged. */
    private class KeepOriginal : RuntimeException()

    @RequiresApi(Build.VERSION_CODES.P)
    private fun decodeP(resolver: ContentResolver, uri: Uri): Bitmap? {
        return try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
                val (w, h) = fit(info.size.width, info.size.height)
                if (info.mimeType in keepAsIs && w == info.size.width && h == info.size.height) throw KeepOriginal()
                decoder.setTargetSize(w, h)
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } catch (_: KeepOriginal) {
            null
        } catch (_: Exception) {
            null
        }
    }

    /** API 26–27: BitmapFactory with sampling, then the EXIF orientation by hand. */
    private fun decodeLegacy(resolver: ContentResolver, uri: Uri): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // Bounds only: decodeStream returns null here by design.
        val stream = resolver.openInputStream(uri) ?: return null
        stream.use { BitmapFactory.decodeStream(it, null, bounds) }
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0) return null
        val (w, h) = fit(width, height)
        val orientation = orientation(resolver, uri)
        val turn = upright(orientation)
        // Keep the existing passthrough: a copied original retains its mirror tag,
        // so only a plain rotation forces a re-encode here.
        if (bounds.outMimeType in keepAsIs && w == width && h == height && (turn.mirror || turn.degrees == 0)) return null
        var sample = 1
        while (max(width, height) / (sample * 2) >= MAX_SIDE) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) } ?: return null
        val matrix = Matrix().apply {
            val (fw, fh) = fit(decoded.width, decoded.height)
            postScale(fw.toFloat() / decoded.width, fh.toFloat() / decoded.height)
        }
        upright(matrix, orientation)
        if (matrix.isIdentity) return decoded
        val transformed = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        if (transformed !== decoded) decoded.recycle()
        return transformed
    }

    /** The EXIF orientation of the image at [uri]; normal when it has none or can't be read. */
    internal fun orientation(resolver: ContentResolver, uri: Uri): Int = try {
        resolver.openInputStream(uri)?.use {
            ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } ?: ExifInterface.ORIENTATION_NORMAL
    } catch (_: Exception) {
        ExifInterface.ORIENTATION_NORMAL
    }

    /** A clockwise turn, then a horizontal mirror: what one EXIF orientation needs to stand upright. */
    internal data class Upright(val degrees: Int, val mirror: Boolean)

    /** A vertical flip is the half turn mirrored; transpose and transverse are quarter turns mirrored. */
    internal fun upright(orientation: Int): Upright = when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90 -> Upright(90, false)
        ExifInterface.ORIENTATION_ROTATE_180 -> Upright(180, false)
        ExifInterface.ORIENTATION_ROTATE_270 -> Upright(270, false)
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> Upright(0, true)
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> Upright(180, true)
        ExifInterface.ORIENTATION_TRANSPOSE -> Upright(90, true)
        ExifInterface.ORIENTATION_TRANSVERSE -> Upright(270, true)
        else -> Upright(0, false)
    }

    /** Adds [orientation]'s turn after whatever [matrix] already does. */
    internal fun upright(matrix: Matrix, orientation: Int): Matrix = matrix.apply {
        val turn = upright(orientation)
        if (turn.degrees != 0) postRotate(turn.degrees.toFloat())
        if (turn.mirror) postScale(-1f, 1f)
    }
}
