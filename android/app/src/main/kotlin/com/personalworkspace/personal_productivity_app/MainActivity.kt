package com.personalworkspace.personal_productivity_app

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.ComponentName
import android.content.pm.PackageManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var pending: MethodChannel.Result? = null
    private val prefs by lazy { getSharedPreferences("taskiya", MODE_PRIVATE) }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val handler = MethodChannel.MethodCallHandler { call, result ->
            try {
                when(call.method) {
                    "refreshWidgets" -> { TaskiyaData.refresh(this); result.success(null) }
                    "pinWidget" -> {
                        val manager = AppWidgetManager.getInstance(this)
                        val notes = call.argument<String>("kind") == "notes"
                        val provider = ComponentName(this, if (notes) NotesWidget::class.java else TodayTasksWidget::class.java)
                        result.success(Build.VERSION.SDK_INT >= 26 && manager.isRequestPinAppWidgetSupported && manager.requestPinAppWidget(provider, null, null))
                    }
                    "scheduleReminder" -> {
                        val id=call.argument<String>("id") ?: ""
                        val title=call.argument<String>("title") ?: "Task"
                        val due=call.argument<String>("dueAt") ?: ""
                        if(id.isNotEmpty() && due.isNotEmpty()) NiyaReminders.schedule(this,id,title,due)
                        result.success(null)
                    }
                    "cancelReminder" -> { call.argument<String>("id")?.let { NiyaReminders.cancel(this,it) }; result.success(null) }
                    "getStatus" -> result.success(mapOf(
                        "overlay" to Settings.canDrawOverlays(this),
                        "notifications" to (Build.VERSION.SDK_INT<33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED),
                        "exactAlarms" to (Build.VERSION.SDK_INT<31 || getSystemService(AlarmManager::class.java).canScheduleExactAlarms()),
                        "niyaEnabled" to prefs.getBoolean("niya_enabled",false),
                        "niyaPaused" to prefs.getBoolean("niya_paused",false),
                        "petKind" to prefs.getString("pet_kind","niya"),
                        "customPetPath" to CustomPet.savedPath(this),
                        "ringtone" to (prefs.getString("ringtone_uri",null) ?: "System default")
                    ))
                    "pickPetPhoto" -> {
                        pending=result
                        try {
                            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                type="image/*"
                                addCategory(Intent.CATEGORY_OPENABLE)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            },303)
                        } catch (error: Exception) {
                            pending=null
                            result.error("PET_PICKER",error.message,null)
                        }
                    }
                    "setPetKind" -> {
                        CustomPet.select(this,call.argument<String>("kind") ?: "niya")
                        refreshPet()
                        result.success(null)
                    }
                    "deletePetPhoto" -> {
                        CustomPet.remove(this)
                        refreshPet()
                        result.success(null)
                    }
                    "startNiya" -> {
                        prefs.edit().putBoolean("niya_enabled",true).putBoolean("niya_paused",false).apply()
                        if(Settings.canDrawOverlays(this)) { startNiya(); result.success(true) }
                        else { startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))); result.success(false) }
                    }
                    "stopNiya" -> { prefs.edit().putBoolean("niya_enabled",false).apply(); stopService(Intent(this,NiyaOverlayService::class.java)); result.success(null) }
                    "pauseNiya" -> { prefs.edit().putBoolean("niya_paused",true).apply(); stopService(Intent(this,NiyaOverlayService::class.java)); result.success(null) }
                    "requestNotifications" -> { if(Build.VERSION.SDK_INT>=33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS),200); result.success(null) }
                    "requestOverlay" -> { startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,Uri.parse("package:$packageName"))); result.success(null) }
                    "requestExactAlarms" -> { if(Build.VERSION.SDK_INT>=31) startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,Uri.parse("package:$packageName"))); result.success(null) }
                    "openAppPermissions" -> { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:$packageName"))); result.success(null) }
                    "pickRingtone" -> {
                        pending=result
                        startActivityForResult(Intent(RingtoneManager.ACTION_RINGTONE_PICKER).apply {
                            putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE,RingtoneManager.TYPE_RINGTONE or RingtoneManager.TYPE_ALARM or RingtoneManager.TYPE_NOTIFICATION)
                            putExtra(RingtoneManager.EXTRA_RINGTONE_TITLE,"DAYNIX reminder ringtone")
                            putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT,true)
                            prefs.getString("ringtone_uri",null)?.takeIf { it!="silent" }?.let { putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI,Uri.parse(it)) }
                        },301)
                    }
                    "pickNotePhoto" -> {
                        Log.i("DaynixPhoto", "opening picker")
                        pending = result
                        try {
                            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                type = "image/*"
                                addCategory(Intent.CATEGORY_OPENABLE)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }, 304)
                        } catch (error: Exception) {
                            pending = null
                            result.error("NOTE_PHOTO_PICKER", error.message, null)
                        }
                    }
                    "deleteNotePhoto" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(NotePhotoStore.delete(this, path))
                    }
                    "pickAttachment" -> {
                        pending=result
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type="*/*"; addCategory(Intent.CATEGORY_OPENABLE); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) },302)
                    }
                    "openAttachment" -> {
                        val uri = Uri.parse(call.argument<String>("uri") ?: throw IllegalArgumentException("Missing attachment"))
                        startActivity(Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, contentResolver.getType(uri) ?: "*/*")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        })
                        result.success(null)
                    }
                    "setOption" -> {
                        val key=call.argument<String>("key") ?: ""
                        when(key) {
                            "hide_seconds","pet_size","lead_seconds" -> prefs.edit().putInt(key,call.argument<Int>("value") ?: 10).apply()
                            "pet_opacity" -> prefs.edit().putFloat(key,(call.argument<Double>("value") ?: .5).toFloat()).apply()
                            "lock_privacy","preferred_edge" -> prefs.edit().putString(key,call.argument<String>("value") ?: "private").apply()
                            else -> prefs.edit().putBoolean(key,call.argument<Boolean>("value") ?: false).apply()
                        }
                        if (key == "preferred_edge") prefs.edit().remove("pet_x").apply()
                        if (key == "lead_seconds") NiyaReminders.reschedule(this)
                        if (prefs.getBoolean("niya_enabled",false)) {
                            val action=if(key=="pet_size" || key=="pet_opacity" || key=="preferred_edge" || key=="hide_seconds") "taskiya.overlay.APPLY_SETTINGS" else "taskiya.overlay.REFRESH"
                            try { startService(Intent(this,NiyaOverlayService::class.java).apply { this.action=action }) } catch (_:Exception) { }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch(error: Exception) { result.error("DAYNIX_NATIVE",error.message,null) }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"taskiya/native").setMethodCallHandler(handler)
    }
    private fun startNiya() {
        val intent=Intent(this,NiyaOverlayService::class.java)
        if(Build.VERSION.SDK_INT>=26) startForegroundService(intent) else startService(intent)
    }
    private fun refreshPet() {
        if (prefs.getBoolean("niya_enabled",false) && !prefs.getBoolean("niya_paused",false) && Settings.canDrawOverlays(this)) {
            try { startService(Intent(this,NiyaOverlayService::class.java).apply { action="taskiya.overlay.APPLY_SETTINGS" }) }
            catch (_: Exception) { }
        }
    }
    override fun onResume() {
        super.onResume()
        if(prefs.getBoolean("niya_enabled",false) && !prefs.getBoolean("niya_paused",false) && Settings.canDrawOverlays(this)) try { startNiya() } catch (_:Exception) { }
    }
    override fun onActivityResult(requestCode: Int,resultCode: Int,data: Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if (requestCode == 304) Log.i("DaynixPhoto", "picker result code=$resultCode uriPresent=${data?.data != null} clipPresent=${data?.clipData != null} callbackPresent=${pending != null}")
        val callback=pending ?: return
        pending=null
        if(resultCode!=Activity.RESULT_OK) { callback.success(null); return }
        if(requestCode==301) {
            val uri = if(Build.VERSION.SDK_INT>=33) data?.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI,Uri::class.java) else @Suppress("DEPRECATION") data?.getParcelableExtra<Uri>(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
            prefs.edit().putString("ringtone_uri",uri?.toString() ?: "silent").apply()
            callback.success(uri?.toString() ?: "Silent")
        } else if(requestCode==302) {
            val uri=data?.data
            if(uri!=null) try { contentResolver.takePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION) } catch (_:Exception) { }
            callback.success(uri?.toString())
        } else if(requestCode==303) {
            val uri=data?.data
            if(uri==null) { callback.error("PET_PICKER","No photo selected",null); return }
            Thread {
                try {
                    val path=CustomPet.importPhoto(this,uri)
                    runOnUiThread { refreshPet(); callback.success(path) }
                } catch(error: Exception) {
                    runOnUiThread { callback.error("PET_IMPORT",error.message ?: "Could not stylize photo",null) }
                }
            }.start()
        } else if(requestCode==304) {
            val uri = data?.data ?: data?.clipData?.getItemAt(0)?.uri
            if(uri==null) { callback.success(null); return }
            Thread {
                try {
                    val path = NotePhotoStore.importPhoto(this, uri)
                    Log.i("DaynixPhoto", "import succeeded")
                    runOnUiThread { callback.success(path) }
                } catch(error: Exception) {
                    Log.e("DaynixPhoto", "import failed: ${error.javaClass.simpleName}")
                    runOnUiThread { callback.error("NOTE_PHOTO_IMPORT", error.message ?: "Could not import photo", null) }
                }
            }.start()
        } else callback.success(null)
    }
}

