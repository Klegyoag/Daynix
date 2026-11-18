package com.personalworkspace.personal_productivity_app

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.UUID

internal data class TaskItem(val id: String, val title: String, val dueAt: String?, val priority: Int)
internal data class NoteItem(val id: String, val title: String, val body: String, val pinned: Boolean)

internal object TaskiyaData {
    private fun open(context: Context): SQLiteDatabase {
        val file = context.getDatabasePath("productivity.db")
        file.parentFile?.mkdirs()
        val db = SQLiteDatabase.openOrCreateDatabase(file, null)
        db.execSQL("PRAGMA foreign_keys=ON")
        if (db.version == 0) {
            db.beginTransaction()
            try {
                db.execSQL("CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY,title TEXT NOT NULL,description TEXT,dueAt TEXT,priority INTEGER NOT NULL DEFAULT 1,completed INTEGER NOT NULL DEFAULT 0,createdAt TEXT NOT NULL,project TEXT,labels TEXT,location TEXT,attachmentUri TEXT,reminderEnabled INTEGER NOT NULL DEFAULT 1)")
                db.execSQL("CREATE TABLE IF NOT EXISTS notes(id TEXT PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,updatedAt TEXT NOT NULL,pinned INTEGER NOT NULL DEFAULT 0,folder TEXT,tags TEXT)")
                db.execSQL("CREATE TABLE IF NOT EXISTS habits(id TEXT PRIMARY KEY,title TEXT NOT NULL,doneDay TEXT)")
                db.execSQL("CREATE TABLE IF NOT EXISTS dumps(id TEXT PRIMARY KEY,body TEXT NOT NULL,createdAt TEXT NOT NULL)")
                db.execSQL("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
                db.execSQL("CREATE TABLE IF NOT EXISTS subtasks(id TEXT PRIMARY KEY,taskId TEXT NOT NULL,title TEXT NOT NULL,completed INTEGER NOT NULL DEFAULT 0,FOREIGN KEY(taskId) REFERENCES tasks(id) ON DELETE CASCADE)")
                migrateV3(db)
                db.version = 3
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
        } else if (db.version == 1) {
            db.beginTransaction()
            try {
                for (sql in listOf("ALTER TABLE tasks ADD COLUMN project TEXT", "ALTER TABLE tasks ADD COLUMN labels TEXT", "ALTER TABLE tasks ADD COLUMN location TEXT", "ALTER TABLE tasks ADD COLUMN attachmentUri TEXT", "ALTER TABLE tasks ADD COLUMN reminderEnabled INTEGER NOT NULL DEFAULT 1", "ALTER TABLE notes ADD COLUMN folder TEXT", "ALTER TABLE notes ADD COLUMN tags TEXT")) db.execSQL(sql)
                db.execSQL("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
                db.execSQL("CREATE TABLE IF NOT EXISTS subtasks(id TEXT PRIMARY KEY,taskId TEXT NOT NULL,title TEXT NOT NULL,completed INTEGER NOT NULL DEFAULT 0,FOREIGN KEY(taskId) REFERENCES tasks(id) ON DELETE CASCADE)")
                migrateV3(db)
                db.version = 3
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
        } else if (db.version == 2) {
            db.beginTransaction()
            try { migrateV3(db); db.version = 3; db.setTransactionSuccessful() } finally { db.endTransaction() }
        }
        return db
    }

    private fun migrateV3(db: SQLiteDatabase) {
        db.execSQL("ALTER TABLE tasks ADD COLUMN recurrence TEXT NOT NULL DEFAULT 'none'")
        db.execSQL("CREATE TABLE IF NOT EXISTS task_occurrences(taskId TEXT NOT NULL,scheduledAt TEXT NOT NULL,completedAt TEXT NOT NULL,PRIMARY KEY(taskId,scheduledAt),FOREIGN KEY(taskId) REFERENCES tasks(id) ON DELETE CASCADE)")
        db.execSQL("CREATE INDEX IF NOT EXISTS task_due_index ON tasks(dueAt,completed)")
    }

    fun setting(context: Context, key: String, fallback: String = ""): String = try {
        open(context).use { db -> db.rawQuery("SELECT value FROM settings WHERE key=?", arrayOf(key)).use { c -> if (c.moveToFirst()) c.getString(0) else fallback } }
    } catch (_: Exception) { fallback }

    fun tasks(context: Context, filter: String, limit: Int): List<TaskItem> = try {
        open(context).use { db ->
            val today = LocalDate.now()
            val selection = when (filter) {
                "tomorrow" -> "AND substr(dueAt,1,10)='${today.plusDays(1)}'"
                "main" -> ""
                "today" -> "AND (dueAt IS NULL OR substr(dueAt,1,10)='$today')"
                else -> if (filter.startsWith("date:") && Regex("\\d{4}-\\d{2}-\\d{2}").matches(filter.removePrefix("date:")))
                    "AND substr(dueAt,1,10)='${filter.removePrefix("date:")}'"
                    else "AND (dueAt IS NULL OR substr(dueAt,1,10)='$today')"
            }
            db.rawQuery("SELECT id,title,dueAt,priority FROM tasks WHERE completed=0 $selection ORDER BY priority DESC,dueAt ASC,createdAt DESC LIMIT $limit", null).use { c ->
                buildList { while (c.moveToNext()) add(TaskItem(c.getString(0), c.getString(1), if (c.isNull(2)) null else c.getString(2), c.getInt(3))) }
            }
        }
    } catch (_: Exception) { emptyList() }

    fun notes(context: Context, filter: String, limit: Int): List<NoteItem> = try {
        open(context).use { db ->
            val where = when (filter) { "pinned" -> "WHERE pinned=1"; "folder" -> "WHERE folder IS NOT NULL AND folder!=''"; else -> "" }
            db.rawQuery("SELECT id,title,body,pinned FROM notes $where ORDER BY pinned DESC,updatedAt DESC LIMIT $limit", null).use { c ->
                buildList { while (c.moveToNext()) add(NoteItem(c.getString(0), c.getString(1), c.getString(2), c.getInt(3)==1)) }
            }
        }
    } catch (_: Exception) { emptyList() }

    fun note(context: Context, id: String): NoteItem? = try {
        open(context).use { db -> db.rawQuery("SELECT id,title,body,pinned FROM notes WHERE id=?", arrayOf(id)).use { c -> if (c.moveToFirst()) NoteItem(c.getString(0),c.getString(1),c.getString(2),c.getInt(3)==1) else null } }
    } catch (_: Exception) { null }

    fun todayProgress(context: Context): Pair<Int, Int> = try {
        open(context).use { db ->
            val day = LocalDate.now().toString()
            db.rawQuery("SELECT COUNT(*), COALESCE(SUM(completed),0) FROM tasks WHERE dueAt IS NULL OR substr(dueAt,1,10)=?", arrayOf(day)).use { cursor ->
                if (cursor.moveToFirst()) Pair(cursor.getInt(1), cursor.getInt(0)) else Pair(0, 0)
            }
        }
    } catch (_: Exception) { Pair(0, 0) }

    fun addTask(context: Context, title: String, description: String? = null, dueAt: String? = null,
                priority: Int = 1, project: String? = null, labels: String? = null,
                location: String? = null, attachmentUri: String? = null, reminderEnabled: Boolean = true, recurrence: String = "none"): String {
        val id = UUID.randomUUID().toString()
        open(context).use { db -> db.execSQL("INSERT INTO tasks(id,title,description,dueAt,priority,completed,createdAt,project,labels,location,attachmentUri,reminderEnabled,recurrence) VALUES(?,?,?,?,?,0,?,?,?,?,?,?,?)",
            arrayOf<Any?>(id,title.trim(),description,dueAt,priority,LocalDateTime.now().toString(),project,labels,location,attachmentUri,if(reminderEnabled) 1 else 0,recurrence)) }
        refresh(context)
        if (dueAt != null && reminderEnabled) NiyaReminders.schedule(context, id, title, dueAt)
        return id
    }

    fun addNote(context: Context, title: String, body: String, id: String? = null) {
        val key = id ?: UUID.randomUUID().toString()
        open(context).use { db -> db.execSQL("INSERT INTO notes(id,title,body,updatedAt,pinned) VALUES(?,?,?,?,0) ON CONFLICT(id) DO UPDATE SET title=excluded.title,body=excluded.body,updatedAt=excluded.updatedAt", arrayOf(key,title.trim().ifEmpty { "Untitled" },body,LocalDateTime.now().toString())) }
        refresh(context)
    }

    fun complete(context: Context, id: String) {
        var next: Triple<String,String,String>? = null
        open(context).use { db ->
            db.beginTransaction()
            try {
                db.rawQuery("SELECT title,dueAt,recurrence,reminderEnabled FROM tasks WHERE id=? AND completed=0",arrayOf(id)).use { c ->
                    if(c.moveToFirst()) {
                        val title=c.getString(0); val due=if(c.isNull(1)) null else c.getString(1); val rule=c.getString(2)
                        val upcoming=due?.let { Recurrence.next(it,rule) }
                        if(upcoming!=null) {
                            db.execSQL("INSERT OR IGNORE INTO task_occurrences(taskId,scheduledAt,completedAt) VALUES(?,?,?)",arrayOf(id,due,LocalDateTime.now().toString()))
                            db.execSQL("UPDATE tasks SET dueAt=? WHERE id=? AND completed=0",arrayOf(upcoming,id))
                            if(c.getInt(3)==1) next=Triple(id,title,upcoming)
                        } else db.execSQL("UPDATE tasks SET completed=1 WHERE id=? AND completed=0", arrayOf(id))
                    }
                }
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
        }
        NiyaReminders.cancel(context, id)
        next?.let { NiyaReminders.schedule(context,it.first,it.second,it.third) }
        refresh(context)
    }

    fun advanceAlarm(context: Context, id: String) {
        var next: Triple<String,String,String>? = null
        open(context).use { db ->
            db.beginTransaction()
            try {
                db.rawQuery("SELECT title,dueAt,recurrence,reminderEnabled FROM tasks WHERE id=? AND completed=0", arrayOf(id)).use { c ->
                    if (c.moveToFirst() && !c.isNull(1)) {
                        val title = c.getString(0)
                        val upcoming = Recurrence.next(c.getString(1), c.getString(2))
                        if (upcoming != null) {
                            db.execSQL("UPDATE tasks SET dueAt=? WHERE id=? AND completed=0", arrayOf(upcoming,id))
                            if (c.getInt(3)==1) next=Triple(id,title,upcoming)
                        }
                    }
                }
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
        }
        next?.let { NiyaReminders.schedule(context,it.first,it.second,it.third) }
        refresh(context)
    }

    fun isOpen(context: Context, id: String): Boolean = try {
        open(context).use { db ->
            db.rawQuery("SELECT 1 FROM tasks WHERE id=? AND completed=0", arrayOf(id)).use { it.moveToFirst() }
        }
    } catch (_: Exception) { false }

    fun allScheduled(context: Context): List<Triple<String,String,String>> = try {
        open(context).use { db -> db.rawQuery("SELECT id,title,dueAt FROM tasks WHERE completed=0 AND dueAt IS NOT NULL AND reminderEnabled=1", null).use { c -> buildList { while (c.moveToNext()) add(Triple(c.getString(0),c.getString(1),c.getString(2))) } } }
    } catch (_: Exception) { emptyList() }

    fun epochMillis(localIso: String): Long? = try { LocalDateTime.parse(localIso).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli() } catch (_: Exception) { null }

    fun refresh(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        manager.getAppWidgetIds(ComponentName(context, TodayTasksWidget::class.java)).forEach { TodayTasksWidget.update(context, manager, it) }
        manager.getAppWidgetIds(ComponentName(context, NotesWidget::class.java)).forEach { NotesWidget.update(context, manager, it) }
    }
}
