package io.github.ccch1mneyyy.dsh_app.companion

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import java.util.Calendar

/**
 * 伙伴小屋 on the home screen: the little pixel whale, her name, what she's doing, the last thing
 * she said, and how well she knows you (lib/companion/companion_widget.dart).
 *
 * The app sends what the room looks like through MethodChannel `dsh/companion_widget` (`update`);
 * it is kept in this module's own preferences and drawn on every widget. Between visits the
 * provider only moves her between awake and asleep with the hour and lets an activity run out.
 * Tapping opens the room through the app's own page link, `dshgo://open/companion`.
 */
class CompanionWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        draw(context, manager, ids)
    }

    companion object {
        private const val STORE = "companion_widget"

        /** What she said stays on the widget this long. */
        private const val LINE_MS = 12 * 3600_000L

        fun store(context: Context, values: Map<*, *>) {
            val edit = context.getSharedPreferences(STORE, Context.MODE_PRIVATE).edit()
            for ((key, value) in values) {
                if (key !is String) continue
                when (value) {
                    is String -> edit.putString(key, value)
                    is Number -> edit.putLong(key, value.toLong())
                    null -> edit.remove(key)
                }
            }
            edit.apply()
        }

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, CompanionWidgetProvider::class.java))
            if (ids.isNotEmpty()) draw(context, manager, ids)
        }

        private fun draw(context: Context, manager: AppWidgetManager, ids: IntArray) {
            val prefs = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
            val night = hour >= 23 || hour < 6
            val activity = prefs.getString("activity", "idle")
            val busy = activity != null && activity != "idle" && prefs.getLong("untilMs", 0) > now
            val status = when {
                busy -> prefs.getString("status", null)
                night -> prefs.getString("statusAsleep", null) ?: AppStrings.get(context, R.string.companion_widget_asleep)
                else -> prefs.getString("statusWaiting", null) ?: AppStrings.get(context, R.string.companion_widget_waiting)
            } ?: ""
            val line = prefs.getString("line", null)?.takeIf { now - prefs.getLong("saidAt", 0) < LINE_MS } ?: ""
            val bond = prefs.getLong("bond", -1).coerceIn(-1, 3)
            val pearls = if (bond >= 0) "●".repeat((bond + 1).toInt()) + "○".repeat((3 - bond).toInt()) else ""
            val image = when {
                night && !busy -> R.drawable.companion_widget_sleeping
                bond >= 2 -> R.drawable.companion_widget_happy
                else -> R.drawable.companion_widget_idle
            }
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(Intent.ACTION_VIEW, Uri.parse("dshgo://open/companion"))
                    .setPackage(context.packageName)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            for (id in ids) {
                val views = RemoteViews(context.packageName, R.layout.companion_widget)
                views.setTextViewText(
                    R.id.companion_widget_name,
                    prefs.getString("name", null) ?: AppStrings.get(context, R.string.companion_widget_name),
                )
                views.setTextViewText(R.id.companion_widget_bond, pearls)
                views.setTextViewText(R.id.companion_widget_status, status)
                views.setTextViewText(R.id.companion_widget_line, line)
                views.setViewVisibility(R.id.companion_widget_line, if (line.isEmpty()) View.GONE else View.VISIBLE)
                views.setImageViewResource(R.id.companion_widget_whale, image)
                views.setOnClickPendingIntent(R.id.companion_widget_root, open)
                manager.updateAppWidget(id, views)
            }
        }
    }
}

/** MethodChannel `dsh/companion_widget`: `update` keeps what the app sends and redraws. */
class CompanionWidgetPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "dsh/companion_widget").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "update" -> {
                val values = call.arguments as? Map<*, *>
                if (values != null) {
                    CompanionWidgetProvider.store(context, values)
                    CompanionWidgetProvider.refresh(context)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
