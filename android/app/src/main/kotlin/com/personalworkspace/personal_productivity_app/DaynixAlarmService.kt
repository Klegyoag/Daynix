package com.personalworkspace.personal_productivity_app

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator

/** Short-lived foreground ringing session. Snooze/Dismiss work without opening Flutter. */
class DaynixAlarmService : Service() {
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { stopSelf() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val id = intent?.getStringExtra("id") ?: return START_NOT_STICKY
        currentId = id
        val title = intent.getStringExtra("title") ?: "Alarm"
        val notification = NiyaReminders.ringingNotification(this, id, title)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(id.hashCode(), notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)
        } else {
            startForeground(id.hashCode(), notification)
        }
        player?.release()
        val selected = getSharedPreferences("taskiya", MODE_PRIVATE).getString("ringtone_uri", null)
        if (selected != "silent") {
            val sound = selected?.let(Uri::parse)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            if (sound != null) {
                try {
                    player = MediaPlayer().apply {
                        setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
                        setDataSource(this@DaynixAlarmService, sound)
                        isLooping = true
                        prepare()
                        start()
                    }
                } catch (_: Exception) {
                    player?.release()
                    player = null
                }
            }
        }
        vibrator = getSystemService(Vibrator::class.java)
        if (checkSelfPermission(Manifest.permission.VIBRATE) == PackageManager.PERMISSION_GRANTED) {
            if (Build.VERSION.SDK_INT >= 26) {
                vibrator?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 500, 500), 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(longArrayOf(0, 500, 500), 0)
            }
        }
        handler.removeCallbacks(timeout)
        handler.postDelayed(timeout, 2 * 60 * 1000L)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        currentId = null
        handler.removeCallbacks(timeout)
        player?.stop()
        player?.release()
        player = null
        vibrator?.cancel()
        super.onDestroy()
    }

    companion object {
        const val STOP = "daynix.alarm.STOP"
        private var currentId: String? = null
        fun stop(context: Context, id: String) {
            if (currentId == id) context.stopService(Intent(context, DaynixAlarmService::class.java))
        }
    }
}

class DaynixAlarmActivity : Activity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        val id = intent.getStringExtra("id") ?: ""
        val title = intent.getStringExtra("title") ?: "Alarm"
        val locked = getSystemService(KeyguardManager::class.java).isKeyguardLocked
        val privacy = getSharedPreferences("taskiya", MODE_PRIVATE).getString("lock_privacy", "private")
        val shownTitle = if (locked && privacy != "show") "DAYNIX alarm" else title
        val root = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER
            setPadding(28, 28, 28, 28)
            setBackgroundColor(android.graphics.Color.rgb(25, 12, 25))
        }
        root.addView(android.widget.TextView(this).apply {
            text = "DAYNIX  •  ALARM"
            textSize = 17f
            setTextColor(android.graphics.Color.rgb(255, 130, 180))
            gravity = android.view.Gravity.CENTER
        })
        root.addView(android.widget.TextView(this).apply {
            text = shownTitle
            textSize = 31f
            setTextColor(android.graphics.Color.WHITE)
            gravity = android.view.Gravity.CENTER
            setPadding(0, 50, 0, 50)
        })
        root.addView(android.widget.Button(this).apply {
            text = "Snooze 5 minutes"
            setOnClickListener { NiyaReminders.snooze(this@DaynixAlarmActivity, id, title); finish() }
        })
        root.addView(android.widget.Button(this).apply {
            text = "Dismiss"
            setOnClickListener { NiyaReminders.dismiss(this@DaynixAlarmActivity, id); finish() }
        })
        setContentView(root)
    }
}
