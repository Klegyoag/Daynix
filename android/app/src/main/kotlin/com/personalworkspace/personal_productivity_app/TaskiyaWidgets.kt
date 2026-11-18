package com.personalworkspace.personal_productivity_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.widget.RemoteViews
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.security.SecureRandom

internal object WidgetPrefs {
    private fun actionToken(context: Context): String {
        val prefs = context.getSharedPreferences("taskiya_widget_security", Context.MODE_PRIVATE)
        prefs.getString("action_token", null)?.let { return it }
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        val token = bytes.joinToString("") { "%02x".format(it) }
        prefs.edit().putString("action_token", token).commit()
        return token
    }
    fun authorized(context: Context, intent: Intent): Boolean =
        intent.getStringExtra("widget_auth") == actionToken(context)

    fun get(context: Context, id: Int, key: String, fallback: String): String =
        context.getSharedPreferences("taskiya_widgets", Context.MODE_PRIVATE).getString("${id}_$key", fallback) ?: fallback
    fun set(context: Context, id: Int, key: String, value: String) {
        context.getSharedPreferences("taskiya_widgets", Context.MODE_PRIVATE).edit().putString("${id}_$key", value).apply()
    }
    fun clear(context: Context, id: Int) {
        context.getSharedPreferences("taskiya_widgets", Context.MODE_PRIVATE).edit()
            .remove("${id}_filter").remove("${id}_theme").apply()
    }
    fun dark(context: Context, id: Int): Boolean {
        val setting = get(context, id, "theme", TaskiyaData.setting(context, "widget_theme", "system"))
        return when (setting) { "dark" -> true; "light" -> false; else -> context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES }
    }
    fun intent(context: Context, widgetId: Int, action: String, extra: String? = null, note: Boolean = false): PendingIntent {
        val cls = if (note) NotesWidget::class.java else TodayTasksWidget::class.java
        val intent = Intent(context, cls).apply {
            this.action = action
            data = Uri.parse("taskiya://widget/$widgetId/$action/${extra ?: "none"}")
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            putExtra("item_id", extra)
            putExtra("widget_auth", actionToken(context))
        }
        return PendingIntent.getBroadcast(context, widgetId, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    fun capture(context: Context, widgetId: Int, kind: String, id: String? = null): PendingIntent {
        val intent = Intent(context, QuickCaptureActivity::class.java).apply {
            action = "taskiya.capture.$kind"
            data = Uri.parse("taskiya://capture/$widgetId/$kind/${id ?: "new"}")
            putExtra("kind", kind)
            putExtra("item_id", id)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
        }
        return PendingIntent.getActivity(context, widgetId, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    fun config(context: Context, widgetId: Int, kind: String): PendingIntent {
        val intent = Intent(context, WidgetConfigActivity::class.java).apply {
            data = Uri.parse("taskiya://config/$widgetId/$kind")
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            putExtra("kind", kind)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
        }
        return PendingIntent.getActivity(context, widgetId, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    fun datePicker(context: Context, widgetId: Int): PendingIntent {
        val intent = Intent(context, WidgetDateActivity::class.java).apply {
            data = Uri.parse("taskiya://widget-date/$widgetId")
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
        }
        return PendingIntent.getActivity(context, widgetId, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}

class TodayTasksWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { update(context, manager, it) } }
    override fun onDeleted(context: Context, ids: IntArray) { ids.forEach { WidgetPrefs.clear(context,it) } }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, widgetId: Int, options: android.os.Bundle) { update(context, manager, widgetId) }
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1)
        if (intent.action in setOf(ACTION_TOGGLE, ACTION_FILTER, ACTION_REFRESH) &&
            !WidgetPrefs.authorized(context, intent)) return
        when (intent.action) {
            ACTION_TOGGLE -> intent.getStringExtra("item_id")?.let { TaskiyaData.complete(context, it) }
            ACTION_FILTER -> {
                if (widgetId >= 0) WidgetPrefs.set(context, widgetId, "filter", intent.getStringExtra("item_id") ?: "today")
                TaskiyaData.refresh(context)
            }
            ACTION_REFRESH -> TaskiyaData.refresh(context)
        }
    }
    companion object {
        const val ACTION_TOGGLE = "taskiya.widget.TOGGLE_TASK"
        const val ACTION_FILTER = "taskiya.widget.TASK_FILTER"
        const val ACTION_REFRESH = "taskiya.widget.REFRESH"
        fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val dark = WidgetPrefs.dark(context, id)
            val views = RemoteViews(context.packageName, if (dark) R.layout.widget_today_dark else R.layout.widget_today)
            val filter = WidgetPrefs.get(context, id, "filter", "today")
            val height = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180)
            val limit = if (height < 155) 2 else 3
            val tasks = TaskiyaData.tasks(context, filter, limit)
            views.setTextViewText(R.id.widget_title, "D A Y N I X")
            views.setTextViewText(R.id.widget_hero, when(filter) { "tomorrow" -> "Tomorrow"; "main" -> "Main Tasks"; else -> "Today Matters" })
            views.setTextViewText(R.id.widget_date, LocalDate.now().format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.getDefault())))
            val progress = TaskiyaData.todayProgress(context)
            views.setTextViewText(R.id.widget_progress, "${progress.first}/${progress.second} completed today")
            for ((viewId, value) in listOf(R.id.tab_today to "today", R.id.tab_tomorrow to "tomorrow", R.id.tab_main to "main")) {
                views.setOnClickPendingIntent(viewId, WidgetPrefs.intent(context, id, ACTION_FILTER, value))
                views.setInt(viewId, "setBackgroundResource", if (filter == value) R.drawable.widget_add else android.R.color.transparent)
                views.setTextColor(viewId, if (filter == value) android.graphics.Color.WHITE else if (dark) android.graphics.Color.rgb(255,154,196) else android.graphics.Color.rgb(179,62,115))
            }
            views.setOnClickPendingIntent(R.id.tab_date, WidgetPrefs.datePicker(context,id))
            views.setOnClickPendingIntent(R.id.widget_add, WidgetPrefs.capture(context, id, "task"))
            views.setOnClickPendingIntent(R.id.widget_title, WidgetPrefs.config(context, id, "tasks"))
            for ((index, viewId) in listOf(R.id.task_1, R.id.task_2, R.id.task_3).withIndex()) {
                val item = tasks.getOrNull(index)
                val dueLabel = item?.dueAt?.let { if (it.length >= 16) " · ${it.substring(11,16)}" else "" } ?: ""
                views.setTextViewText(viewId, if (item == null) { if (index==0) "No tasks here · tap + to add" else "" } else "○  ${item.title}$dueLabel")
                if (item != null) views.setOnClickPendingIntent(viewId, WidgetPrefs.intent(context, id, ACTION_TOGGLE, item.id))
                else views.setOnClickPendingIntent(viewId, WidgetPrefs.capture(context, id, "task"))
            }
            manager.updateAppWidget(id, views)
        }
    }
}

class NotesWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { update(context, manager, it) } }
    override fun onDeleted(context: Context, ids: IntArray) { ids.forEach { WidgetPrefs.clear(context,it) } }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, widgetId: Int, options: android.os.Bundle) { update(context, manager, widgetId) }
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action in setOf(ACTION_FILTER, ACTION_REFRESH) &&
            !WidgetPrefs.authorized(context, intent)) return
        if (intent.action == ACTION_FILTER) {
            val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1)
            if (id >= 0) WidgetPrefs.set(context, id, "filter", intent.getStringExtra("item_id") ?: "recent")
            TaskiyaData.refresh(context)
        } else if (intent.action == ACTION_REFRESH) TaskiyaData.refresh(context)
    }
    companion object {
        const val ACTION_FILTER = "taskiya.widget.NOTE_FILTER"
        const val ACTION_REFRESH = "taskiya.widget.NOTES_REFRESH"
        fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, if (WidgetPrefs.dark(context,id)) R.layout.widget_notes_dark else R.layout.widget_notes)
            val filter = WidgetPrefs.get(context,id,"filter","recent")
            val height = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT,180)
            val notes = TaskiyaData.notes(context,filter,if(height<155) 2 else 3)
            views.setTextViewText(R.id.widget_title,"D A Y N I X")
            views.setTextViewText(R.id.widget_hero,"Notes")
            views.setTextViewText(R.id.widget_date, LocalDate.now().format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault())))
            views.setTextViewText(R.id.widget_progress,"${notes.size} ${if(notes.size==1) "note" else "notes"} shown")
            for ((viewId,value) in listOf(R.id.tab_recent to "recent",R.id.tab_pinned to "pinned",R.id.tab_folder to "folder")) {
                views.setOnClickPendingIntent(viewId, WidgetPrefs.intent(context,id,ACTION_FILTER,value,note=true))
                views.setInt(viewId, "setBackgroundResource", if (filter == value) R.drawable.widget_add else android.R.color.transparent)
                views.setTextColor(viewId, if (filter == value) android.graphics.Color.WHITE else if (WidgetPrefs.dark(context,id)) android.graphics.Color.rgb(255,154,196) else android.graphics.Color.rgb(179,62,115))
            }
            views.setOnClickPendingIntent(R.id.widget_add, WidgetPrefs.capture(context,id,"note"))
            views.setOnClickPendingIntent(R.id.widget_title, WidgetPrefs.config(context,id,"notes"))
            for ((index,viewId) in listOf(R.id.note_1,R.id.note_2,R.id.note_3).withIndex()) {
                val note = notes.getOrNull(index)
                views.setTextViewText(viewId, if(note==null) { if(index==0) "No notes here · tap + to write" else "" } else "${if(note.pinned) "♧" else "▤"}  ${note.title} · ${note.body.take(24).replace('\n',' ')}")
                views.setOnClickPendingIntent(viewId, WidgetPrefs.capture(context,id,if(note==null) "note" else "editNote",note?.id))
            }
            manager.updateAppWidget(id,views)
        }
    }
}

