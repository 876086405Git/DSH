package io.github.ccch1mneyyy.dsh_app.phone

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import java.io.ByteArrayOutputStream

/** Installed apps' names and icons for the phone pages (the skills page shows the apps a skill works in). */
internal object PhoneAppInfo {
    private const val ICON_PX = 96
    private const val MAX_PACKAGES = 64

    fun read(ctx: Context, packages: List<String>): Map<String, Map<String, Any>> {
        val pm = ctx.packageManager
        return packages.distinct().take(MAX_PACKAGES).mapNotNull { pkg ->
            val info = try {
                pm.getApplicationInfo(pkg, 0)
            } catch (_: PackageManager.NameNotFoundException) {
                return@mapNotNull null
            }
            pkg to mapOf("label" to pm.getApplicationLabel(info).toString(), "icon" to png(pm.getApplicationIcon(info)))
        }.toMap()
    }

    private fun png(icon: android.graphics.drawable.Drawable): ByteArray {
        val bitmap = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
        icon.setBounds(0, 0, ICON_PX, ICON_PX)
        icon.draw(Canvas(bitmap))
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            out.toByteArray()
        }
    }
}
