package com.personalworkspace.personal_productivity_app

import android.Manifest
import android.app.AlarmManager
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.time.Instant

internal object NiyaReminders {
    private const val REMINDER_CHANNEL = "taskiya_reminders"
    private const val ACTION_ALARM = "taskiya.reminder.ALARM"
    private const val ACTION_DONE = "taskiya.reminder.DONE"
    private const val ACTION_SNOOZE = "taskiya.reminder.SNOOZE"
    private const val ACTION_DISMISS = "taskiya.reminder.DISMISS"
    private const val ALARM_CHANNEL = "daynix_alarm_ringing_v1"
    private fun prefs(context: Context) = context.getSharedPreferences("taskiya",Context.MODE_PRIVATE)
    private fun notificationBuilder(context: Context, channelId: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channelId) else Notification.Builder(context)
    private fun alarmIntent(context: Context,id: String,title: String): PendingIntent = PendingIntent.getBroadcast(context,id.hashCode(),Intent(context,NiyaAlarmReceiver::class.java).apply {
        action = ACTION_ALARM; data = Uri.parse("taskiya://alarm/$id"); putExtra("id",id); putExtra("title",title)
    },PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun schedule(context: Context,id: String,title: String,dueAt: String) {
        val due = TaskiyaData.epochMillis(dueAt) ?: return
        val lead = prefs(context).getInt("lead_seconds",10).coerceIn(0,3600)
        val whenMs = (due - lead*1000L).coerceAtLeast(System.currentTimeMillis()+1000L)
        if (due < System.currentTimeMillis()) return
        val manager = context.getSystemService(AlarmManager::class.java)
        val pending = alarmIntent(context,id,title)
        manager.cancel(pending)
        if (Build.VERSION.SDK_INT >= 31 && !manager.canScheduleExactAlarms()) manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,whenMs,pending)
        else try { manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,whenMs,pending) }
             catch (_: SecurityException) { manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,whenMs,pending) }
    }
    fun cancel(context: Context,id: String) {
        context.getSystemService(AlarmManager::class.java).cancel(alarmIntent(context,id,""))
        context.getSystemService(NotificationManager::class.java).cancel(id.hashCode())
        DaynixAlarmService.stop(context,id)
        if(prefs(context).getString("pending_reminder_id",null)==id) prefs(context).edit().remove("pending_reminder_id").remove("pending_reminder_title").apply()
    }
    fun snooze(context: Context,id: String,title: String) {
        DaynixAlarmService.stop(context,id)
        if (!TaskiyaData.isOpen(context,id)) return
        val alarm=context.getSystemService(AlarmManager::class.java)
        val pending=alarmIntent(context,id,title)
        val whenMs = System.currentTimeMillis()+5*60*1000L
        if (Build.VERSION.SDK_INT>=31 && !alarm.canScheduleExactAlarms()) alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,whenMs,pending)
        else try { alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,whenMs,pending) }
             catch (_: SecurityException) { alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,whenMs,pending) }
        prefs(context).edit().remove("last_reminder_token").apply()
        context.getSystemService(NotificationManager::class.java).cancel(id.hashCode())
        DaynixAlarmService.stop(context,id)
    }
    fun dismiss(context: Context,id: String) {
        DaynixAlarmService.stop(context,id)
        context.getSystemService(NotificationManager::class.java).cancel(id.hashCode())
        prefs(context).edit().remove("pending_reminder_id").remove("pending_reminder_title").apply()
        TaskiyaData.advanceAlarm(context,id)
    }
    fun reschedule(context: Context) { TaskiyaData.allScheduled(context).forEach { (id,title,due) -> schedule(context,id,title,due) } }

    private fun action(context: Context,action: String,id: String,title: String): PendingIntent = PendingIntent.getBroadcast(context,(id+action).hashCode(),Intent(context,NiyaAlarmReceiver::class.java).apply {
        this.action=action; data=Uri.parse("taskiya://reminder/$action/$id"); putExtra("id",id); putExtra("title",title)
    },PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun ringingNotification(context: Context,id: String,title: String): Notification {
        val manager=context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT>=26) {
            manager.createNotificationChannel(NotificationChannel(ALARM_CHANNEL,"DAYNIX alarms",NotificationManager.IMPORTANCE_HIGH).apply {
                description="Ringing task alarms with snooze and dismiss"
                lockscreenVisibility=Notification.VISIBILITY_PRIVATE
                setSound(null,null)
            })
        }
        val privacy=prefs(context).getString("lock_privacy","private") ?: "private"
        val publicVersion=notificationBuilder(context,ALARM_CHANNEL).setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("DAYNIX alarm").setContentText("A task alarm is ringing.").build()
        val open=PendingIntent.getActivity(context,id.hashCode(),Intent(context,DaynixAlarmActivity::class.java).apply {
            flags=Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("id",id); putExtra("title",title)
        },PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder=notificationBuilder(context,ALARM_CHANNEL).setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("DAYNIX alarm").setContentText(title).setContentIntent(open)
            .setCategory(Notification.CATEGORY_ALARM).setOngoing(true)
            .setVisibility(when(privacy) { "show" -> Notification.VISIBILITY_PUBLIC; "hidden" -> Notification.VISIBILITY_SECRET; else -> Notification.VISIBILITY_PRIVATE })
            .setPublicVersion(publicVersion)
            .addAction(Notification.Action.Builder(null,"Snooze 5 min",action(context,ACTION_SNOOZE,id,title)).build())
            .addAction(Notification.Action.Builder(null,"Dismiss",action(context,ACTION_DISMISS,id,title)).build())
            .addAction(Notification.Action.Builder(null,"Done",action(context,ACTION_DONE,id,title)).build())
        if (Build.VERSION.SDK_INT<26) builder.setPriority(Notification.PRIORITY_HIGH).setSound(null)
        if (Build.VERSION.SDK_INT<34 || manager.canUseFullScreenIntent()) builder.setFullScreenIntent(open,true)
        return builder.build()
    }

    fun show(context: Context,id: String,title: String) {
        val locked=context.getSystemService(KeyguardManager::class.java).isKeyguardLocked
        if (locked && prefs(context).getBoolean("niya_enabled",false)) prefs(context).edit()
            .putString("pending_reminder_id",id).putString("pending_reminder_title",title).apply()
        val canNotify=Build.VERSION.SDK_INT<33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED
        if (canNotify) context.getSystemService(NotificationManager::class.java).notify(id.hashCode(),ringingNotification(context,id,title))
        try {
            val service=Intent(context,DaynixAlarmService::class.java).apply { putExtra("id",id); putExtra("title",title) }
            if(Build.VERSION.SDK_INT>=26) context.startForegroundService(service) else context.startService(service)
        } catch (_:Exception) { /* Notification actions remain available if background service launch is restricted. */ }
        if (!locked && Settings.canDrawOverlays(context) && prefs(context).getBoolean("niya_enabled",false)) {
            try { context.startService(Intent(context,NiyaOverlayService::class.java).apply { this.action="taskiya.overlay.REMINDER"; putExtra("id",id); putExtra("title",title) }) } catch (_:Exception) { }
        }
    }

    fun handle(context: Context,intent: Intent) {
        val id=intent.getStringExtra("id") ?: return
        val title=intent.getStringExtra("title") ?: "Task"
        when(intent.action) {
            ACTION_ALARM -> if (TaskiyaData.isOpen(context,id)) show(context,id,title)
            ACTION_DONE -> TaskiyaData.complete(context,id)
            ACTION_SNOOZE -> snooze(context,id,title)
            ACTION_DISMISS -> dismiss(context,id)
        }
    }
}

class NiyaAlarmReceiver: BroadcastReceiver() { override fun onReceive(context: Context,intent: Intent) { NiyaReminders.handle(context,intent) } }
class NiyaRestoreReceiver: BroadcastReceiver() {
    override fun onReceive(context: Context,intent: Intent) {
        if (intent.action==Intent.ACTION_BOOT_COMPLETED || intent.action==Intent.ACTION_TIMEZONE_CHANGED || intent.action==Intent.ACTION_TIME_CHANGED || intent.action==AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED) NiyaReminders.reschedule(context)
        if(intent.action==Intent.ACTION_BOOT_COMPLETED && context.getSharedPreferences("taskiya",Context.MODE_PRIVATE).let { it.getBoolean("niya_enabled",false) && !it.getBoolean("niya_paused",false) } && Settings.canDrawOverlays(context)) {
            try {
                val service=Intent(context,NiyaOverlayService::class.java)
                if(Build.VERSION.SDK_INT>=26) context.startForegroundService(service) else context.startService(service)
            } catch (_:Exception) { /* OEM background limits may defer restoration until the app opens. */ }
        }
    }
}

