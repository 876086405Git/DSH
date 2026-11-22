package io.github.ccch1mneyyy.dsh_app.launch

import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIconPlugin
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons
import org.json.JSONObject

/**
 * Which theme the system's launch window is drawn from, so that it never shows an icon other than
 * the one the person chose (桌面图标) or a colour that doesn't lead into their launch screen.
 * Pure, unit-tested on the JVM; [LaunchThemeSync] applies it.
 *
 * A theme is fixed per activity, and an activity-alias can't have its own, so the manifest's
 * LaunchTheme can't know which icon is on the launcher. It shows none: the page colour alone
 * (12+: a transparent splash icon; 8–11: a window background without the icon). Android 13
 * lets an app choose the splash theme of its next launches (SplashScreen.setSplashScreenTheme):
 * there the chosen icon's own theme (LaunchTheme.Night …) is kept in place, so from then on the
 * splash shows that icon. A system that ignores the choice falls back to the blank theme, never
 * to another icon.
 *
 * With a custom launch screen the splash stays icon-less, on the colour nearest the picture's
 * background (the page, white or black), which the picture then fades in over.
 */
internal object LaunchThemes {
    /** The manifest's LaunchTheme: the page colour, no icon. */
    const val BLANK = "LaunchTheme"
    const val WHITE = "LaunchTheme.White"
    const val BLACK = "LaunchTheme.Black"

    /** The splash with [variant]'s icon (LauncherIcons.variants). */
    fun forIcon(variant: String): String = "LaunchTheme." + variant.replaceFirstChar { it.uppercaseChar() }

    /** Every theme a launch can be given, in R.style order of [LaunchThemeSync]. */
    val all: List<String> get() = listOf(BLANK, WHITE, BLACK) + LauncherIcons.variants.map(::forIcon)

    /** What the stored custom launch screen asks of the splash (null: none, or not in use). */
    data class Custom(val backdrop: String, val edge: Int?)

    /**
     * The theme for the next launches: the custom launch screen's plain colour, else [icon]'s.
     * [dark]: the system is in dark mode now (the page colour follows it).
     */
    fun next(custom: Custom?, dark: Boolean, icon: () -> String): String =
        if (custom != null) plain(custom, dark) else forIcon(icon())

    /** An icon-less splash on the colour nearest the custom picture's background. */
    fun plain(custom: Custom, dark: Boolean): String = when (custom.backdrop) {
        "white" -> WHITE
        "black" -> BLACK
        "edge" -> custom.edge?.let { nearest(it, dark) } ?: BLANK
        else -> BLANK
    }

    /** The page colour (light or dark), white or black, whichever is closest to [argb]. */
    fun nearest(argb: Int, dark: Boolean): String {
        val page = if (dark) PAGE_DARK else PAGE_LIGHT
        return listOf(BLANK to page, WHITE to 0xFFFFFFFF.toInt(), BLACK to 0xFF000000.toInt())
            .minByOrNull { (_, c) -> distance(argb, c) }!!.first
    }

    /** Whether a launch drawn from [applied] shows [icon] in the splash. */
    fun showsIcon(applied: String?, icon: String): Boolean = applied != null && applied == forIcon(icon)

    /** The background the splash of [applied] lays (ARGB), [dark] for the page colour. */
    fun background(applied: String?, dark: Boolean): Int = when (applied) {
        WHITE -> 0xFFFFFFFF.toInt()
        BLACK -> 0xFF000000.toInt()
        else -> if (dark) PAGE_DARK else PAGE_LIGHT
    }

    private fun distance(a: Int, b: Int): Int {
        fun ch(c: Int, s: Int) = (c shr s) and 0xFF
        val dr = ch(a, 16) - ch(b, 16)
        val dg = ch(a, 8) - ch(b, 8)
        val db = ch(a, 0) - ch(b, 0)
        return dr * dr + dg * dg + db * db
    }

    /** res/values{,-night}/colors.xml launch_background_top (LaunchGeometryTest keeps them equal). */
    const val PAGE_LIGHT = 0xFFEBF1FE.toInt()
    const val PAGE_DARK = 0xFF1D222C.toInt()
}

/**
 * Keeps Android 13+'s splash theme on [LaunchThemes.next] (applied for the next launches), and
 * remembers what was applied: a launch reads it to know what its own splash showed.
 */
internal object LaunchThemeSync {
    private const val TAG = "DshLaunch"
    private const val PREFS = "launch_theme"
    private const val KEY_APPLIED = "applied"

    /** Flutter's shared_preferences store and the custom launch screen's key (lib/launch/custom_launch.dart). */
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val K_CUSTOM = "flutter.launch_custom"

    /** The splash theme this launch was drawn from (null: the manifest's, blank). */
    fun applied(context: Context): String? = if (Build.VERSION.SDK_INT >= 33) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_APPLIED, null)
    } else {
        null
    }

    /** The custom launch screen in use, as the splash needs it; null without one. */
    fun custom(context: Context): LaunchThemes.Custom? = try {
        val raw = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE).getString(K_CUSTOM, null)
        val json = raw?.let(::JSONObject)
        if (json == null || !json.optBoolean("on", true)) {
            null
        } else {
            LaunchThemes.Custom(json.optString("backdrop", "auto"), if (json.has("edge")) json.getInt("edge") else null)
        }
    } catch (_: Exception) {
        null
    }

    fun dark(context: Context) =
        (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    /** Brings the next launches' splash theme in line with the icon and launch screen now. Main thread. */
    fun sync(activity: Activity) {
        if (Build.VERSION.SDK_INT < 33) return
        try {
            val want = LaunchThemes.next(custom(activity), dark(activity)) { LauncherIconPlugin.current(activity) }
            val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (prefs.getString(KEY_APPLIED, null) == want) return
            activity.splashScreen.setSplashScreenTheme(styleOf(want))
            prefs.edit().putString(KEY_APPLIED, want).commit()
        } catch (e: Exception) {
            // Not applied: the next launch is taken to be blank (it never assumes an icon).
            Log.w(TAG, "splash theme: ${e.javaClass.simpleName}")
            activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY_APPLIED).commit()
        }
    }

    private fun styleOf(name: String): Int = when (name) {
        LaunchThemes.WHITE -> R.style.LaunchTheme_White
        LaunchThemes.BLACK -> R.style.LaunchTheme_Black
        LaunchThemes.forIcon(LauncherIcons.MIST) -> R.style.LaunchTheme_Mist
        LaunchThemes.forIcon(LauncherIcons.NIGHT) -> R.style.LaunchTheme_Night
        LaunchThemes.forIcon(LauncherIcons.FROST) -> R.style.LaunchTheme_Frost
        LaunchThemes.forIcon(LauncherIcons.INK) -> R.style.LaunchTheme_Ink
        // Back to the manifest's (blank).
        else -> Resources.ID_NULL
    }
}
