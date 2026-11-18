package com.personalworkspace.personal_productivity_app

import android.app.Activity
import android.app.AlertDialog
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.content.res.Configuration
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.ViewGroup
import android.view.View
import android.widget.EditText
import android.widget.ArrayAdapter
import android.widget.CheckBox
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import java.time.LocalDate
import java.time.LocalDateTime

class QuickCaptureActivity : Activity() {
    private var attachmentUri: String? = null
    private var attachmentLabel: TextView? = null
    private val dark: Boolean get() = when(TaskiyaData.setting(this,"theme_mode","dark")) {
        "dark" -> true
        "light" -> false
        else -> resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    }
    private val accent: Int get() = Color.rgb(255,145,187)
    private val ink: Int get() = if(dark) Color.rgb(250,239,246) else Color.rgb(40,27,43)
    private val surface: Int get() = if(dark) Color.rgb(30,23,31) else Color.rgb(255,249,252)
    private val regular by lazy { if(android.os.Build.VERSION.SDK_INT>=26) resources.getFont(R.font.roboto_regular) else Typeface.DEFAULT }
    private val bold by lazy { Typeface.create(regular,Typeface.BOLD) }
    private fun dp(value: Int) = (value*resources.displayMetrics.density).toInt()
    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply { setColor(color); cornerRadius=dp(radius).toFloat() }
    override fun onCreate(savedInstanceState: Bundle?) {
        applyDaynixDialogTheme()
        super.onCreate(savedInstanceState)
        val kind = intent.getStringExtra("kind") ?: "task"
        if (kind == "note" || kind == "editNote") showNote() else showTask()
    }

    private fun column(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        val p = dp(18)
        setPadding(p,p,p,p)
        background=rounded(surface,24)
    }
    private fun field(hint: String, minLines: Int = 1): EditText = EditText(this).apply {
        this.hint = hint
        this.minLines = minLines
        if (minLines > 1) gravity = Gravity.TOP
        textSize=16f
        typeface=regular
        setTextColor(ink)
        setHintTextColor(if(dark) Color.rgb(174,160,174) else Color.rgb(117,103,117))
        backgroundTintList=ColorStateList.valueOf(accent)
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT)
    }
    private fun heading(label: String) = TextView(this).apply {
        text=label; textSize=13f; typeface=bold; setTextColor(accent); setPadding(0,dp(13),0,dp(5))
    }
    private fun pill(label: String, action: () -> Unit)=TextView(this).apply {
        text=label; textSize=13f; typeface=regular; gravity=Gravity.CENTER; setTextColor(ink)
        background=rounded(if(dark) Color.rgb(66,43,59) else Color.rgb(255,222,236),13)
        setPadding(dp(10),dp(10),dp(10),dp(10)); setOnClickListener { action() }
    }
    private fun titleView(label: String)=LinearLayout(this).apply {
        orientation=LinearLayout.HORIZONTAL; gravity=Gravity.CENTER_VERTICAL; setPadding(dp(18),dp(14),dp(18),0)
        addView(ImageView(this@QuickCaptureActivity).apply {
            CustomPet.currentPath(this@QuickCaptureActivity)?.let { path ->
                setImageBitmap(android.graphics.BitmapFactory.decodeFile(path))
            } ?: setImageResource(PetCatalog.drawable(this@QuickCaptureActivity))
            scaleType=ImageView.ScaleType.FIT_CENTER
        },LinearLayout.LayoutParams(dp(50),dp(50)))
        addView(TextView(this@QuickCaptureActivity).apply { text=label; textSize=19f; typeface=bold; setTextColor(ink); setPadding(dp(10),0,0,0) })
    }
    private fun showTask() {
        val layout = column()
        val title = field("Task title")
        val desc = field("Description (optional)",2)
        val project = field("Project (optional)")
        val labels = field("Labels, comma separated")
        val location = field("Location (optional)")
        val priority = Spinner(this).apply {
            adapter = ArrayAdapter(this@QuickCaptureActivity, android.R.layout.simple_spinner_dropdown_item,
                arrayOf("Low priority","Medium priority","High priority","Urgent priority"))
            setSelection(1)
        }
        val repeatOptions=arrayOf("Does not repeat","Daily","Mon to Fri","Weekly","Monthly","Custom weekdays")
        val repeatValues=arrayOf("none","daily","weekdays","weekly","monthly","custom")
        val repeat=Spinner(this).apply { adapter=ArrayAdapter(this@QuickCaptureActivity,android.R.layout.simple_spinner_dropdown_item,repeatOptions) }
        val customDays=field("Custom days, e.g. 1,3,5 (Mon=1)").apply { visibility=View.GONE }
        repeat.onItemSelectedListener=object: android.widget.AdapterView.OnItemSelectedListener {
            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) { }
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                customDays.visibility=if(position==5) View.VISIBLE else View.GONE
            }
        }
        val remind = CheckBox(this).apply { text = "Remind me 10 seconds before the scheduled time"; isChecked = true; typeface=regular }
        val due = TextView(this).apply { text = "No date selected"; textSize = 15f; typeface=regular; setTextColor(ink); setPadding(0,dp(7),0,dp(8)) }
        val attachment = TextView(this).apply {
            text = "Attach a file (optional)"; textSize = 16f; typeface=regular; setPadding(0,18,0,18)
            setOnClickListener {
                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    type = "*/*"; addCategory(Intent.CATEGORY_OPENABLE)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }, 401)
            }
        }
        attachmentLabel = attachment
        var chosen: LocalDateTime? = null
        val pickDate = {
            val now = LocalDate.now()
            DatePickerDialog(this,{ _,year,month,day ->
                val old=chosen
                chosen=LocalDateTime.of(year,month+1,day,old?.hour ?: 9,old?.minute ?: 0)
                due.text="Scheduled · $chosen"
            },now.year,now.monthValue-1,now.dayOfMonth).show()
        }
        val dateRow=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL }
        listOf("☀ Today" to 0,"☁ Tomorrow" to 1).forEach { (label,offset) ->
            dateRow.addView(pill(label) { val day=LocalDate.now().plusDays(offset.toLong()); chosen=day.atTime(chosen?.hour ?: 9,chosen?.minute ?: 0); due.text="Scheduled · $chosen" },LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1f).apply { marginEnd=dp(6) })
        }
        dateRow.addView(pill("▦ Pick date") { pickDate() },LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1f))
        val timeChip=pill("◷ Choose time") {
            val old=chosen
            TimePickerDialog(this,{ _,hour,minute ->
                chosen=(old?.toLocalDate() ?: LocalDate.now()).atTime(hour,minute)
                due.text="Scheduled · $chosen"
            },old?.hour ?: 9,old?.minute ?: 0,false).show()
        }
        layout.addView(heading("What needs doing?")); layout.addView(title); layout.addView(desc)
        layout.addView(heading("Schedule")); layout.addView(dateRow); layout.addView(timeChip); layout.addView(due)
        layout.addView(heading("Repeat")); layout.addView(repeat); layout.addView(customDays)
        layout.addView(heading("Details & reminders")); layout.addView(priority)
        layout.addView(project); layout.addView(labels); layout.addView(location); layout.addView(attachment); layout.addView(remind)
        val dialog = AlertDialog.Builder(this).setCustomTitle(titleView("DAYNIX · Add task"))
            .setView(ScrollView(this).apply { addView(layout) })
            .setNegativeButton("Cancel") { _,_ -> finishAndRemoveTask() }
            .setPositiveButton("Add",null).create()
        dialog.setOnShowListener {
            dialog.window?.setBackgroundDrawable(rounded(surface,24))
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setTextColor(accent)
            dialog.getButton(AlertDialog.BUTTON_NEGATIVE).setTextColor(accent)
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).typeface=bold
            dialog.getButton(AlertDialog.BUTTON_NEGATIVE).typeface=regular
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val text = title.text.toString().trim()
                if (text.isEmpty()) { title.error = "Enter a task"; return@setOnClickListener }
                val selectedRule=repeatValues[repeat.selectedItemPosition]
                val rule=if(selectedRule=="custom") "custom:${customDays.text.toString().filter { it.isDigit() || it==',' }}" else selectedRule
                if(rule!="none" && (chosen==null || rule=="custom:")) { due.error="Choose date, time and repeat days"; return@setOnClickListener }
                try { TaskiyaData.addTask(this,text,desc.text.toString(),chosen?.toString(),priority.selectedItemPosition,
                    project.text.toString(),labels.text.toString(),location.text.toString(),attachmentUri,remind.isChecked,rule); dialog.dismiss(); finishAndRemoveTask() }
                catch (error: Exception) { title.error = error.message ?: "Could not save task" }
            }
        }
        dialog.setOnDismissListener { finishAndRemoveTask() }; dialog.show()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 401 && resultCode == RESULT_OK) {
            val uri = data?.data ?: return
            try { contentResolver.takePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION) } catch (_:Exception) { }
            attachmentUri = uri.toString()
            attachmentLabel?.text = "Attachment selected"
        }
    }

    private fun showNote() {
        val existing = intent.getStringExtra("item_id")?.let { TaskiyaData.note(this,it) }
        val layout = column()
        val title = field("Note title").apply { setText(existing?.title ?: "") }
        val body = field("Write a note...",5).apply { setText(existing?.body ?: "") }
        layout.addView(title); layout.addView(body)
        val dialog = AlertDialog.Builder(this).setTitle(if(existing==null) "DAYNIX · Quick note" else "DAYNIX · Edit note")
            .setView(ScrollView(this).apply { addView(layout) })
            .setNegativeButton("Cancel") { _,_ -> finish() }
            .setPositiveButton("Save",null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if(title.text.isBlank() && body.text.isBlank()) { title.error="Write something"; return@setOnClickListener }
                try { TaskiyaData.addNote(this,title.text.toString(),body.text.toString(),existing?.id); dialog.dismiss(); finish() }
                catch(error: Exception) { title.error=error.message ?: "Could not save note" }
            }
        }
        dialog.setOnDismissListener { finish() }; dialog.show()
    }
}

private fun Activity.applyDaynixDialogTheme() {
    val mode = TaskiyaData.setting(this, "theme_mode", "system")
    val dark = when (mode) {
        "dark" -> true
        "light" -> false
        else -> resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    }
    setTheme(if (dark) R.style.TaskiyaDialogDarkTheme else R.style.TaskiyaDialogTheme)
}

class WidgetConfigActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        applyDaynixDialogTheme()
        super.onCreate(savedInstanceState)
        val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,-1)
        if(widgetId<0) { finish(); return }
        val kind = intent.getStringExtra("kind") ?: "tasks"
        val themes = arrayOf("Follow system","Light pastel","Dark pastel")
        val keys = arrayOf("system","light","dark")
        val current = WidgetPrefs.get(this,widgetId,"theme", "system")
        AlertDialog.Builder(this).setTitle("DAYNIX $kind widget theme")
            .setSingleChoiceItems(themes,keys.indexOf(current).coerceAtLeast(0)) { dialog, which ->
                WidgetPrefs.set(this,widgetId,"theme",keys[which]); TaskiyaData.refresh(this)
                dialog.dismiss(); finish()
            }.setNegativeButton("Close") { _,_ -> finish() }
            .setOnCancelListener { finish() }.show()
    }
}

class WidgetDateActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        applyDaynixDialogTheme()
        super.onCreate(savedInstanceState)
        val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1)
        if (widgetId < 0) { finish(); return }
        val now = LocalDate.now()
        DatePickerDialog(this, { _, year, month, day ->
            val chosen = LocalDate.of(year, month + 1, day)
            WidgetPrefs.set(this, widgetId, "filter", "date:$chosen")
            TaskiyaData.refresh(this)
            finish()
        }, now.year, now.monthValue - 1, now.dayOfMonth)
            .apply { setOnCancelListener { finish() } }
            .show()
    }
}


