package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.graphics.Point
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.SystemClock
import android.view.Display
import android.view.accessibility.AccessibilityWindowInfo
import io.github.ccch1mneyyy.dsh_app.phone.PhoneControl
import io.github.ccch1mneyyy.dsh_app.phone.SafetyRules
import io.github.ccch1mneyyy.dsh_app.phone.ScreenSnapshot

/** Independent read-only capture. It never publishes a PhoneDriver snapshot,
 * replaces its current element IDs, creates a task, or accepts coordinates. */
internal class CompanionScreenSampler(private val service: PhoneA11yService, overlay: ControlOverlay) {
    private val ocr = MlKitLocalOcr.get(service.applicationContext)
    private val shooter = ScreenShooter(service, overlay, ocr)
    private val changes = CompanionScreenChange()
    private var previousText: String? = null
    private var previousPackage: String? = null
    @Volatile private var closed = false

    fun close() { closed = true; shooter.close() }

    fun sample(control: PhoneControl, excluded: Set<String>, current: () -> Boolean): Map<String, Any?> {
        fun live() = !closed && current() && PhoneA11yService.instance === service && !control.isLocked()
        if (!live()) return skipped("inactive")
        if (control.shownControls() != null) return skipped("phone_busy")
        val fresh = Build.VERSION.SDK_INT in 34..37 && runCatching { service.clearCache() }.getOrDefault(false)
        val cap = TreeCapture.capture(service, screenBox(), service.packageName, 1200)
        try {
            if (!live() || !permitted(cap, control, excluded)) { changes.clear(); return skipped("protected") }
            val pkg = cap.packageName!!
            val title = cap.windows.mapNotNull { it.title }.joinToString(" · ")
            val id = "companion-screen"
            val formatted = ScreenFormat.format(ScreenInput(id, null, pkg, cap.screen.width,
                cap.screen.height, cap.keyboardShown, cap.windows))
            val textChanged = previousPackage != pkg || previousText != formatted.text
            var due = false
            val epoch = ocr.enabledEpoch()
            // Keep the original phone OCR qualifications. A change grid alone
            // does not establish the provenance/privacy of pixels to recognize.
            val readLocal = formatted.poorTree && fresh && ocrQualified(cap)
            val shot = shooter.shoot(cap.windows.singleOrNull(), cap.screen, emptyList(), emptyList(), 3500,
                image = false, readLocalText = readLocal && epoch != null,
                localTextPrivacyAllowed = readLocal,
                localTextCancelled = { !live() || ocr.enabledEpoch() != epoch },
                frameWanted = { grid ->
                    due = changes.changed(grid, SystemClock.uptimeMillis(), textChanged)
                    due && readLocal
                })
            if (!live() || shot.secure || shot.error != null || shot.luminanceGrid == null) return skipped("capture_unavailable")
            previousPackage = pkg
            previousText = formatted.text
            if (!due) return skipped("unchanged")
            // A second tree read prevents an already-observed app/page transition
            // during asynchronous screenshot/OCR from being returned as current.
            val checkFresh = Build.VERSION.SDK_INT in 34..37 && runCatching { service.clearCache() }.getOrDefault(false)
            val check = TreeCapture.capture(service, screenBox(), service.packageName, 900)
            try {
                if (!live() || !permitted(check, control, excluded) || check.packageName != pkg ||
                    check.windows.map { it.id } != cap.windows.map { it.id }) return skipped("changed")
                if (formatted.poorTree && (!readLocal || !checkFresh || !ocrQualified(check))) return skipped("ocr_unavailable")
            } finally { check.recycle() }
            val text: String
            val method: String
            if (formatted.poorTree) {
                if (epoch == null || ocr.enabledEpoch() != epoch) return skipped("ocr_unavailable")
                val recognized = shot.localText as? LocalOcrResult.Recognized ?: return skipped("ocr_unavailable")
                val lines = recognized.lines.map { it.text }
                if (lines.isEmpty() || lines.any { SafetyRules.isSecret(it) || ScreenMask.mask(it) != it } ||
                    ProtectedPages.isProtected(pkg, lines.take(8))) return skipped("protected")
                text = lines.joinToString("\n").take(3000)
                method = "ocr"
            } else {
                text = formatted.text
                method = "tree"
            }
            val filtered = control.core.safety.filterScreen(ScreenSnapshot(id, text, null, pkg,
                readPackages = cap.windows.mapNotNull { it.packageName }.toSet()))
            if (!live() || filtered.text != text) return skipped("protected")
            return mapOf("status" to "observed", "observed_at_ms" to System.currentTimeMillis(),
                "package_name" to pkg, "window_title" to ScreenMask.mask(title),
                "capture_method" to method, "text" to text,
                "busy" to busy(cap))
        } finally { cap.recycle() }
    }

    fun permitsCurrent(control: PhoneControl, excluded: Set<String>, packageName: String, requireIdle: Boolean): Boolean {
        if (closed || PhoneA11yService.instance !== service || control.isLocked() || control.shownControls() != null) return false
        if (Build.VERSION.SDK_INT in 34..37) runCatching { service.clearCache() }
        val cap = TreeCapture.capture(service, screenBox(), service.packageName, 900)
        return try { cap.packageName == packageName && permitted(cap, control, excluded) && (!requireIdle || busy(cap) == false) }
        finally { cap.recycle() }
    }

    private fun permitted(cap: Capture, control: PhoneControl, excluded: Set<String>): Boolean {
        val pkg = cap.packageName ?: return false
        if (cap.hiddenWindowTitle != null || cap.unreadableWindowTitle != null || cap.windows.isEmpty() ||
            cap.partial || cap.truncated || secretFieldBounds(cap.windows).isNotEmpty()) return false
        val titles = cap.windows.mapNotNull { it.title } +
            cap.windows.flatMap { ProtectedPages.titleTexts(it.root, cap.screen.height) }
        val packages = cap.windows.map { it.packageName }
        if ((packages + pkg).any { it == null || it in excluded ||
                control.core.safety.checkRead(it, null) != null || ProtectedPages.isProtected(it, titles) }) return false
        if (ScreenFormat.index(cap.windows).any { "«银行卡" in it.fullText || "«身份证" in it.fullText }) return false
        if (Build.VERSION.SDK_INT < 34 || cap.windows.size != 1) {
            // The older API captures the display: all known non-control image
            // sources must pass the same existing phone read policies.
            for (window in cap.imageWindows) {
                if (window.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY &&
                    window.packageName == service.packageName) continue
                val source = window.packageName ?: return false
                if (source in excluded || control.core.safety.checkRead(source, null) != null ||
                    ProtectedPages.isProtected(source, titles)) return false
            }
        }
        return true
    }

    private fun ocrQualified(cap: Capture): Boolean = cap.visualComplete && cap.windows.size == 1 &&
        cap.windows.single().kind == WindowKind.APP && cap.keyboardShown == false &&
        !cap.ownAppInFront && !cap.systemInFront

    private fun busy(cap: Capture): Boolean? {
        if (cap.keyboardShown == true || service.companionActivityAt > 0 &&
            SystemClock.uptimeMillis() - service.companionActivityAt < 1500) return true
        return if (cap.keyboardShown == false) false else null
    }

    private fun screenBox(): Box {
        val point = Point()
        @Suppress("DEPRECATION")
        service.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)?.getRealSize(point)
        return Box(0, 0, point.x.coerceAtLeast(1), point.y.coerceAtLeast(1))
    }

    private fun skipped(reason: String): Map<String, Any?> = mapOf("status" to reason)
}
