package io.github.ccch1mneyyy.dsh_app.icons

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import org.junit.Assert.*
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/** AndroidManifest.xml and res/ against [LauncherIcons] (Gradle runs unit tests in app/android/app). */
class LauncherManifestTest {
    private val main = File("src/main")
    private val ns = "io.github.ccch1mneyyy.dsh_app"

    private fun manifest(): Element {
        val factory = DocumentBuilderFactory.newInstance()
        return factory.newDocumentBuilder().parse(File(main, "AndroidManifest.xml")).documentElement
    }

    private fun Element.children(tag: String): List<Element> {
        val nodes = getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun Element.isLauncher() = children("intent-filter").any { filter ->
        filter.children("action").any { it.getAttribute("android:name") == "android.intent.action.MAIN" } &&
            filter.children("category").any { it.getAttribute("android:name") == "android.intent.category.LAUNCHER" }
    }

    private fun full(name: String) = if (name.startsWith(".")) ns + name else name

    @Test fun theAliasesAreTheLauncherEntries() {
        val app = manifest().children("application").single()
        val aliases = app.children("activity-alias")
        assertEquals(
            LauncherIcons.aliases.map { it.className },
            aliases.map { full(it.getAttribute("android:name")) },
        )
        for ((alias, element) in LauncherIcons.aliases.zip(aliases)) {
            assertEquals(alias.toString(), "$ns.MainActivity", full(element.getAttribute("android:targetActivity")))
            assertEquals(alias.toString(), alias.enabledByManifest.toString(), element.getAttribute("android:enabled"))
            assertEquals("true", element.getAttribute("android:exported"))
            assertTrue(alias.toString(), element.isLauncher())
            // Long-press shortcuts follow the entry.
            assertTrue(element.children("meta-data").any {
                it.getAttribute("android:name") == "android.app.shortcuts" &&
                    it.getAttribute("android:resource") == "@xml/shortcuts"
            })
            // Nothing but the launcher entry: shares, links and the tile stay on their activities.
            assertEquals(1, element.children("intent-filter").size)
        }
        val activities = app.children("activity")
        assertTrue(activities.none { it.isLauncher() })
        val mainActivity = activities.single { it.getAttribute("android:name") == ".MainActivity" }
        // Read by MainActivity.getMetaData for every alias.
        assertTrue(mainActivity.children("meta-data").any { it.getAttribute("android:name") == "flutter_deeplinking_enabled" })
    }

    @Test fun thePhoneShowsTheAppAsDshGo() {
        val app = manifest().children("application").single()
        // The name comes from build.gradle.kts: DSH Go, or DSH Go 测试 for a side test build.
        assertEquals("\${appLabel}", app.getAttribute("android:label"))
        val gradle = File("build.gradle.kts").readText()
        assertTrue(gradle.contains("manifestPlaceholders[\"appLabel\"] = if (sideBuild) \"DSH Go 测试\" else \"DSH Go\""))
        // Notification titles say the same name.
        assertEquals("DSH Go", AppStrings.APP_NAME)
        // Launcher entries, Recents and the share sheet all take the application's label.
        for (element in app.children("activity") + app.children("activity-alias")) {
            assertEquals(element.getAttribute("android:name"), "", element.getAttribute("android:label"))
        }
    }

    @Test fun everyAliasIconShipsAllLayersAndDensities() {
        val app = manifest().children("application").single()
        for (element in app.children("activity-alias")) {
            val icon = element.getAttribute("android:icon").removePrefix("@mipmap/")
            assertEquals("@mipmap/${icon}_round", element.getAttribute("android:roundIcon"))
            for (name in listOf(icon, "${icon}_round")) {
                val adaptive = File(main, "res/mipmap-anydpi-v26/$name.xml").readText()
                val layers = Regex("<(background|foreground|monochrome) android:drawable=\"@(\\w+)/(\\w+)\"")
                    .findAll(adaptive).associate { it.groupValues[1] to (it.groupValues[2] to it.groupValues[3]) }
                assertEquals(name, setOf("background", "foreground", "monochrome"), layers.keys)
                for ((type, res) in layers.values) {
                    if (type == "drawable") assertTrue(res, File(main, "res/drawable/$res.xml").exists())
                    else for (d in DENSITIES) assertTrue("$d/$res", File(main, "res/mipmap-$d/$res.png").exists())
                }
                for (d in DENSITIES) assertTrue("$d/$name", File(main, "res/mipmap-$d/$name.png").exists())
            }
        }
    }

    private companion object {
        val DENSITIES = listOf("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")
    }
}
