package com.personalworkspace.personal_productivity_app

import android.app.KeyguardManager
import android.app.AlertDialog
import android.app.Dialog
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.BitmapFactory
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.NumberPicker
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import android.content.res.Configuration
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.YearMonth
import java.time.format.DateTimeFormatter

class NiyaOverlayService : Service() {
    private lateinit var window: WindowManager
    private var pet: ImageView? = null
    private var frames: NiyaFrames? = null
    private var petParams: WindowManager.LayoutParams? = null
    private var petFullSize = 0
    private var isPeeking = false
    private var panel: View? = null
    private var panelBackdrop: View? = null
    private var captureDate: LocalDate? = null
    private var captureHour: Int? = null
    private var captureMinute: Int? = null
    private var captureRepeat = "none"
    private val captureDays = mutableSetOf<Int>()
    private val handler = Handler(Looper.getMainLooper())
    private val hide = Runnable { peek() }
    private val blink = object : Runnable {
        override fun run() {
            val p = petParams
            if (canShow() && prefs.getBoolean("animations_enabled",true) && !prefs.getBoolean("battery_saver",false) && panel == null && !isPeeking && p != null && p.x >= 0 && p.x <= screenWidth-p.width) {
                pose(NiyaFrames.BLINK, 170L)
            }
            if (pet != null) handler.postDelayed(this, 5200L)
        }
    }
    private val prefs by lazy { getSharedPreferences("taskiya",Context.MODE_PRIVATE) }
    private fun petName() = PetCatalog.name(this)
    private var notificationAvatar: Bitmap? = null
    private fun petAvatar(): Bitmap {
        notificationAvatar?.takeUnless { it.isRecycled }?.let { return it }
        val source=PetCatalog.bitmap(this) ?: BitmapFactory.decodeResource(resources,R.drawable.niya_idle)
        val avatar=Bitmap.createScaledBitmap(source,dp(96),dp(96),true)
        if (avatar !== source) source.recycle()
        notificationAvatar=avatar
        return avatar
    }
    private fun ImageView.usePetImage() {
        val custom=CustomPet.currentPath(this@NiyaOverlayService)?.let { BitmapFactory.decodeFile(it) }
        if (custom != null) setImageBitmap(custom) else setImageResource(PetCatalog.drawable(this@NiyaOverlayService))
        scaleType=ImageView.ScaleType.FIT_CENTER
    }
    private val uiTypeface by lazy { if (Build.VERSION.SDK_INT >= 26) resources.getFont(R.font.roboto_regular) else Typeface.DEFAULT }
    private fun pose(state: Int, returnAfterMs: Long = 0L) {
        val view = pet ?: return
        frames?.show(view, state)
        if (returnAfterMs > 0) handler.postDelayed({
            if (pet === view && canShow()) frames?.show(view, if (panel == null) NiyaFrames.IDLE else NiyaFrames.THINKING)
        }, returnAfterMs)
    }
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    removePanel()
                    pet?.let { try { window.removeView(it) } catch (_: Exception) { } }
                    pet = null
                    petParams = null
                    isPeeking = false
                    handler.removeCallbacks(hide)
                    handler.removeCallbacks(blink)
                    updateNotification()
                }
                Intent.ACTION_USER_PRESENT -> {
                    updateNotification()
                    if (prefs.getBoolean("niya_enabled", false) && !prefs.getBoolean("niya_paused",false)) {
                        showPet()
                        showPendingReminder()
                    }
                }
            }
        }
    }
    private fun dp(n: Int) = (n*resources.displayMetrics.density).toInt()
    private val screenWidth get() = resources.displayMetrics.widthPixels
    private val screenHeight get() = resources.displayMetrics.heightPixels
    private fun card(color: Int, radius: Int = 24) = GradientDrawable().apply { setColor(color); cornerRadius=dp(radius).toFloat() }

    private fun lockScreenNotification(): Notification {
        val open=PendingIntent.getActivity(this,77,Intent(this,MainActivity::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder=if(Build.VERSION.SDK_INT>=26) Notification.Builder(this,"daynix_niya_service_v2") else Notification.Builder(this)
        val lockVisible=prefs.getBoolean("lockscreen_pet_enabled",true) && prefs.getString("lock_privacy","private")!="hidden"
        val locked=getSystemService(KeyguardManager::class.java).isKeyguardLocked
        return builder.setSmallIcon(R.drawable.taskiya_logo)
            .setLargeIcon(petAvatar())
            .setContentTitle("${petName()} · DAYNIX")
            .setContentText(if(locked) "${petName()} is here on your lock screen" else "${petName()} floating assistant is on")
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setVisibility(if(lockVisible) Notification.VISIBILITY_PUBLIC else Notification.VISIBILITY_SECRET)
            .setCategory(Notification.CATEGORY_SERVICE).build()
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java).notify(77,lockScreenNotification())
    }

    override fun onCreate() {
        super.onCreate()
        window=getSystemService(WindowManager::class.java)
        val manager=getSystemService(NotificationManager::class.java)
        if(Build.VERSION.SDK_INT>=26) manager.createNotificationChannel(NotificationChannel("daynix_niya_service_v2","DAYNIX pet assistant",NotificationManager.IMPORTANCE_LOW).apply { lockscreenVisibility=Notification.VISIBILITY_PUBLIC; setSound(null,null) })
        startForeground(77,lockScreenNotification())
        registerReceiver(screenReceiver, IntentFilter().apply { addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_USER_PRESENT) })
        showPet()
        showPendingReminder()
    }
    override fun onStartCommand(intent: Intent?,flags: Int,startId: Int): Int {
        when(intent?.action) {
            "taskiya.overlay.STOP" -> { stopSelf(); return START_NOT_STICKY }
            "taskiya.overlay.REFRESH" -> updateNotification()
            "taskiya.overlay.APPLY_SETTINGS" -> applyPetSettings()
            "taskiya.overlay.REMINDER" -> if (canShow()) {
                restore(); showReminder(intent.getStringExtra("id") ?: "", intent.getStringExtra("title") ?: "Task")
            }
            else -> if (pet==null) showPet()
        }
        return START_STICKY
    }
    override fun onBind(intent: Intent?): IBinder? = null
    private fun canShow(): Boolean = Settings.canDrawOverlays(this) && getSystemService(PowerManager::class.java).isInteractive && !getSystemService(KeyguardManager::class.java).isKeyguardLocked
    private fun showPendingReminder() {
        if(!canShow() || !prefs.getBoolean("niya_enabled",false) || prefs.getBoolean("niya_paused",false)) return
        val id=prefs.getString("pending_reminder_id",null) ?: return
        val title=prefs.getString("pending_reminder_title",null) ?: "Task"
        prefs.edit().remove("pending_reminder_id").remove("pending_reminder_title").apply()
        if(TaskiyaData.isOpen(this,id)) { restore(); showReminder(id,title) }
    }
    private fun params(width: Int,height: Int,focus: Boolean): WindowManager.LayoutParams = WindowManager.LayoutParams(width,height,if(Build.VERSION.SDK_INT>=26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,if(focus) WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL else WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,PixelFormat.TRANSLUCENT).apply { gravity=Gravity.TOP or Gravity.START; softInputMode=WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE }

    private fun showPet() {
        if(!canShow() || pet!=null) return
        val size=dp(prefs.getInt("pet_size",72).coerceIn(48,120))
        petFullSize=size
        val image=ImageView(this).apply { scaleType=ImageView.ScaleType.FIT_CENTER; alpha=1f; contentDescription="${petName()} floating assistant" }
        if (frames == null) frames = NiyaFrames(this)
        frames?.show(image, NiyaFrames.WAVE)
        val preferred = prefs.getString("preferred_edge","auto")
        val defaultX = if (preferred == "left") 0 else screenWidth-size
        val lp=params(size,size,false).apply { x=prefs.getInt("pet_x",defaultX).coerceIn(0,screenWidth-size); y=prefs.getInt("pet_y",screenHeight/3).coerceIn(0,screenHeight-size) }
        try { window.addView(image,lp) } catch (_: Exception) { stopSelf(); return }
        pet=image; petParams=lp
        var startX=0f; var startY=0f; var initialX=0; var initialY=0; var moved=false; var wasPeeking=false; var movementPose=NiyaFrames.IDLE
        image.setOnTouchListener { _,event ->
            when(event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { wasPeeking=isPeeking; if(wasPeeking) restore(); startX=event.rawX; startY=event.rawY; initialX=lp.x; initialY=lp.y; moved=false; handler.removeCallbacks(hide); true }
                MotionEvent.ACTION_MOVE -> { val dx=event.rawX-startX; val dy=event.rawY-startY; if(kotlin.math.abs(dx)>dp(6)||kotlin.math.abs(dy)>dp(6)) moved=true; val next=if(kotlin.math.abs(dx)>dp(100)) NiyaFrames.RUN else NiyaFrames.WALK; if(moved && movementPose!=next) { movementPose=next; pose(next) }; image.scaleX=1f; lp.x=(initialX+dx).toInt().coerceIn(-size+dp(26),screenWidth-dp(26)); lp.y=(initialY+dy).toInt().coerceIn(0,screenHeight-size); window.updateViewLayout(image,lp); true }
                MotionEvent.ACTION_UP -> {
                    if(moved) { lp.x=when(prefs.getString("preferred_edge","auto")) { "left" -> 0; "right" -> screenWidth-size; else -> if(lp.x+size/2<screenWidth/2) 0 else screenWidth-size }; window.updateViewLayout(image,lp); prefs.edit().putInt("pet_x",lp.x).putInt("pet_y",lp.y).apply() }
                    else if (prefs.getBoolean("task_popup_enabled",true)) openPetAi()
                    if(moved) pose(NiyaFrames.IDLE)
                    image.alpha=1f
                    resetHide(); true
                }
                else -> false
            }
        }
        pose(NiyaFrames.WAVE, 850L)
        handler.removeCallbacks(blink)
        handler.postDelayed(blink, 5200L)
        resetHide()
    }
    private fun openPetAi() {
        try {
            startActivity(Intent(this, PetAiActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            })
        } catch (_: Exception) {
            Toast.makeText(this, "Could not open DAYNIX AI", Toast.LENGTH_SHORT).show()
        }
    }
    private fun resetHide() { handler.removeCallbacks(hide); if(panel==null) handler.postDelayed(hide,prefs.getInt("hide_seconds",10).coerceIn(3,60)*1000L) }
    private fun peek() {
        val p=petParams ?: return; val v=pet ?: return
        if(panel!=null || isPeeking) return
        val left=p.x+petFullSize/2<screenWidth/2
        val bitmap=frames?.edgeBitmap() ?: return
        val edgeWidth=(petFullSize.toFloat()*bitmap.width/bitmap.height).toInt().coerceAtLeast(dp(32))
        v.scaleType=ImageView.ScaleType.FIT_XY
        v.scaleX=frames?.edgeScaleX(left) ?: 1f
        v.setImageBitmap(bitmap)
        p.width=edgeWidth
        p.x=if(left) 0 else screenWidth-edgeWidth
        isPeeking=true
        try {
            window.updateViewLayout(v,p)
            if(!prefs.getBoolean("reduced_motion",false)) {
                v.alpha=1f
                v.animate().alpha(prefs.getFloat("pet_opacity",.5f).coerceIn(.2f,.8f)).setDuration(220).start()
            } else {
                v.alpha=prefs.getFloat("pet_opacity",.5f).coerceIn(.2f,.8f)
            }
        } catch (_:Exception) { isPeeking=false; restore() }
    }
    private fun restore() {
        val p=petParams ?: return; val v=pet ?: return
        val left=p.x+p.width/2<screenWidth/2
        p.width=petFullSize
        p.x=if(left) 0 else screenWidth-petFullSize
        isPeeking=false
        v.scaleType=ImageView.ScaleType.FIT_CENTER
        v.scaleX=1f
        v.animate().cancel()
        v.alpha=1f
        try { window.updateViewLayout(v,p) } catch (_:Exception) {}
        pose(NiyaFrames.IDLE); resetHide()
    }
    private fun applyPetSettings() {
        if (panel != null) removePanel()
        val old=pet
        val p=petParams
        if(old!=null && p!=null) {
            prefs.edit().putInt("pet_x",p.x.coerceAtLeast(0)).putInt("pet_y",p.y).apply()
            try { window.removeView(old) } catch (_:Exception) { }
            pet=null; petParams=null; isPeeking=false
            handler.removeCallbacks(hide); handler.removeCallbacks(blink)
        }
        frames?.close(); frames=null
        notificationAvatar?.let { if (!it.isRecycled) it.recycle() }; notificationAvatar=null
        updateNotification()
        showPet()
    }
    private fun isDark() = when(TaskiyaData.setting(this,"theme_mode","dark")) {
        "dark" -> true
        "light" -> false
        else -> resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    }
    private fun text(value: String,size: Float=15f,bold: Boolean=false)=TextView(this).apply { text=value; textSize=size; setTextColor(if(isDark()) Color.rgb(246,237,247) else Color.rgb(28,27,56)); typeface=if(bold) Typeface.create(uiTypeface,Typeface.BOLD) else uiTypeface; setPadding(dp(4),dp(6),dp(4),dp(6)) }
    private fun button(label: String, click: () -> Unit)=Button(this).apply { text=label; textSize=12f; isAllCaps=false; typeface=uiTypeface; setTextColor(if(isDark()) Color.WHITE else Color.rgb(58,29,48)); background=card(if(isDark()) Color.rgb(82,48,69) else Color.rgb(255,207,226),12); setOnClickListener { click() } }
    private fun clearCapture() {
        captureDate=null; captureHour=null; captureMinute=null; captureRepeat="none"; captureDays.clear()
    }
    private fun showOverlayDialog(dialog: Dialog) {
        dialog.window?.setType(if(Build.VERSION.SDK_INT>=26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE)
        dialog.window?.setBackgroundDrawable(card(if(isDark()) Color.rgb(33,26,36) else Color.rgb(255,249,252),22))
        dialog.show()
    }
    private fun pickerTheme() = if(isDark()) R.style.TaskiyaDialogDarkTheme else R.style.TaskiyaDialogTheme
    private fun showDateChoice(filter: String, draft: String) {
        val dark=isDark()
        val ink=if(dark) Color.rgb(249,239,248) else Color.rgb(31,28,47)
        val muted=if(dark) Color.rgb(176,161,178) else Color.rgb(103,95,119)
        val accent=Color.rgb(255,119,174)
        val root=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; setPadding(dp(16),dp(8),dp(16),dp(5)) }
        var chosen=captureDate ?: LocalDate.now()
        var month=YearMonth.from(chosen)
        val heading=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL; gravity=Gravity.CENTER_VERTICAL }
        val monthText=TextView(this).apply { textSize=16f; typeface=Typeface.create(uiTypeface,Typeface.BOLD); setTextColor(ink); gravity=Gravity.CENTER_VERTICAL }
        val previous=TextView(this).apply { text="‹"; textSize=32f; gravity=Gravity.CENTER; setTextColor(accent); contentDescription="Previous month" }
        val next=TextView(this).apply { text="›"; textSize=32f; gravity=Gravity.CENTER; setTextColor(accent); contentDescription="Next month" }
        heading.addView(monthText,LinearLayout.LayoutParams(0,dp(42),1f).apply { gravity=Gravity.CENTER_VERTICAL })
        heading.addView(previous,LinearLayout.LayoutParams(dp(36),dp(42)))
        heading.addView(next,LinearLayout.LayoutParams(dp(36),dp(42)))
        root.addView(heading)
        val weekdays=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL }
        for(day in arrayOf("M","T","W","T","F","S","S")) weekdays.addView(TextView(this).apply {
            text=day; textSize=11f; typeface=uiTypeface; gravity=Gravity.CENTER; setTextColor(muted)
        },LinearLayout.LayoutParams(0,dp(28),1f))
        root.addView(weekdays)
        val grid=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL }
        root.addView(grid)
        fun render() {
            monthText.text=month.atDay(1).format(DateTimeFormatter.ofPattern("MMMM yyyy"))
            grid.removeAllViews()
            val offset=month.atDay(1).dayOfWeek.value-1
            val start=month.atDay(1).minusDays(offset.toLong())
            val weeks=(offset+month.lengthOfMonth()+6)/7
            for(week in 0 until weeks) {
                val row=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL }
                for(column in 0..6) {
                    val day=start.plusDays((week*7+column).toLong())
                    row.addView(TextView(this).apply {
                        text=day.dayOfMonth.toString(); textSize=14f; typeface=uiTypeface; gravity=Gravity.CENTER
                        setTextColor(if(day==chosen) Color.WHITE else if(YearMonth.from(day)==month) ink else muted)
                        background=when {
                            day==chosen -> card(accent,12)
                            day==LocalDate.now() -> card(if(dark) Color.rgb(77,50,69) else Color.rgb(255,226,238),12)
                            else -> null
                        }
                        contentDescription=day.format(DateTimeFormatter.ofPattern("EEEE, MMMM d, yyyy"))
                        setOnClickListener { chosen=day; month=YearMonth.from(day); render() }
                    },LinearLayout.LayoutParams(0,dp(38),1f).apply { setMargins(dp(1),dp(1),dp(1),dp(1)) })
                }
                grid.addView(row)
            }
        }
        previous.setOnClickListener { month=month.minusMonths(1); render() }
        next.setOnClickListener { month=month.plusMonths(1); render() }
        render()
        showOverlayDialog(AlertDialog.Builder(this,pickerTheme())
            .setTitle("Pick a date")
            .setView(root)
            .setNeutralButton("Today") { _,_ -> captureDate=LocalDate.now(); showPanel(filter,draft) }
            .setNegativeButton("Cancel",null)
            .setPositiveButton("Use date") { _,_ -> captureDate=chosen; showPanel(filter,draft) }
            .create())
    }
    private fun showTimeChoice(filter: String, draft: String) {
        val root=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; setPadding(dp(18),dp(6),dp(18),dp(8)) }
        val heading=TextView(this).apply {
            text="Set a time for this task"; textSize=14f; typeface=uiTypeface
            setTextColor(if(isDark()) Color.rgb(239,225,236) else Color.rgb(57,43,57))
        }
        root.addView(heading)
        val pickers=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL; gravity=Gravity.CENTER }
        fun picker(min: Int,max: Int,current: Int,displayed: Array<String>?=null)=NumberPicker(this).apply {
            minValue=min; maxValue=max; wrapSelectorWheel=true
            if(displayed!=null) displayedValues=displayed
            value=current
            if(Build.VERSION.SDK_INT>=29) {
                setTextColor(if(isDark()) Color.WHITE else Color.rgb(45,35,48))
                setTextSize(17f*resources.displayMetrics.scaledDensity)
                setSelectionDividerHeight(dp(1))
            }
        }
        val selectedHour=captureHour ?: 9
        val hours=picker(1,12,((selectedHour+11)%12)+1)
        val minutes=picker(0,59,captureMinute ?: 0,Array(60) { it.toString().padStart(2,'0') })
        var chosenPeriod=if(selectedHour>=12) 1 else 0
        val periodColumn=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; gravity=Gravity.CENTER }
        val am=TextView(this).apply { text="AM"; textSize=14f; typeface=uiTypeface; gravity=Gravity.CENTER }
        val pm=TextView(this).apply { text="PM"; textSize=14f; typeface=uiTypeface; gravity=Gravity.CENTER }
        fun refreshPeriod() {
            for((index,view) in listOf(am,pm).withIndex()) {
                view.setTextColor(if(index==chosenPeriod) Color.WHITE else Color.rgb(172,151,166))
                view.background=if(index==chosenPeriod) card(Color.rgb(221,93,146),12) else null
            }
        }
        am.setOnClickListener { chosenPeriod=0; refreshPeriod() }
        pm.setOnClickListener { chosenPeriod=1; refreshPeriod() }
        periodColumn.addView(am,LinearLayout.LayoutParams(dp(57),dp(41)).apply { bottomMargin=dp(5) })
        periodColumn.addView(pm,LinearLayout.LayoutParams(dp(57),dp(41)))
        refreshPeriod()
        pickers.addView(hours,LinearLayout.LayoutParams(0,dp(150),1f))
        pickers.addView(minutes,LinearLayout.LayoutParams(0,dp(150),1f))
        pickers.addView(periodColumn,LinearLayout.LayoutParams(0,dp(150),1f))
        root.addView(pickers)
        val dialog=AlertDialog.Builder(this,pickerTheme())
            .setTitle("Choose time")
            .setView(root)
            .setNegativeButton("Cancel",null)
            .setPositiveButton("Set time") { _,_ ->
                captureDate=captureDate ?: when(filter) { "tomorrow" -> LocalDate.now().plusDays(1); else -> LocalDate.now() }
                captureHour=(hours.value%12)+if(chosenPeriod==1) 12 else 0
                captureMinute=minutes.value
                showPanel(filter,draft)
            }.create()
        showOverlayDialog(dialog)
    }
    private fun removePanel() {
        panel?.let { try { window.removeView(it) } catch (_:Exception){} }
        panelBackdrop?.let { try { window.removeView(it) } catch (_:Exception){} }
        panel=null; panelBackdrop=null; pose(NiyaFrames.IDLE); resetHide()
    }
    private fun showPanel(filter: String="today", draft: String="") {
        if(!canShow()) return
        removePanel(); handler.removeCallbacks(hide)
        pose(NiyaFrames.THINKING)
        pet?.alpha=1f
        val dark=isDark()
        val foreground=if(dark) Color.rgb(249,239,248) else Color.rgb(29,30,56)
        val muted=if(dark) Color.rgb(187,176,192) else Color.rgb(104,110,135)
        val surface=if(dark) Color.rgb(33,29,41) else Color.rgb(255,248,252)
        val soft=if(dark) Color.rgb(52,44,59) else Color.rgb(255,232,242)
        val accent=if(dark) Color.rgb(255,119,174) else Color.rgb(242,76,143)
        val line=if(dark) Color.rgb(71,62,79) else Color.rgb(240,220,233)
        fun label(value: String,size: Float,bold: Boolean=false,color: Int=foreground)=TextView(this).apply {
            text=value; textSize=size; setTextColor(color); typeface=Typeface.create(uiTypeface,if(bold) Typeface.BOLD else Typeface.NORMAL)
        }
        fun rounded(fill: Int,radius: Int,stroke: Int?=null)=card(fill,radius).apply { if(stroke!=null) setStroke(dp(1),stroke) }
        fun space(h: Int)=View(this).apply { layoutParams=LinearLayout.LayoutParams(1,dp(h)) }
        val container=LinearLayout(this).apply {
            orientation=LinearLayout.VERTICAL; setPadding(dp(16),dp(14),dp(16),dp(14)); background=rounded(surface,26,line); elevation=dp(18).toFloat()
        }
        val head=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL; gravity=Gravity.CENTER_VERTICAL }
        head.addView(ImageView(this).apply { usePetImage() },LinearLayout.LayoutParams(dp(48),dp(48)))
        val titleBlock=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; setPadding(dp(8),0,0,0); addView(label(petName(),19f,true)); addView(label("Your DAYNIX assistant",11f,false,muted)) }
        head.addView(titleBlock,LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1f))
        head.addView(TextView(this).apply { text="×"; textSize=23f; gravity=Gravity.CENTER; setTextColor(muted); background=rounded(soft,12); contentDescription="Close assistant"; setOnClickListener { clearCapture(); removePanel() } },LinearLayout.LayoutParams(dp(36),dp(36)))
        container.addView(head)
        container.addView(space(10))
        val input=EditText(this).apply {
            hint="What needs doing?"; setSingleLine(true); textSize=15f; typeface=uiTypeface; setTextColor(foreground); setHintTextColor(muted)
            background=null; setPadding(dp(12),0,dp(8),0); setText(draft)
        }
        val inputRow=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL; gravity=Gravity.CENTER_VERTICAL; background=rounded(soft,18,line) }
        inputRow.addView(input,LinearLayout.LayoutParams(0,dp(50),1f))
        inputRow.addView(TextView(this).apply {
            text="+"; textSize=29f; gravity=Gravity.CENTER; setTextColor(Color.WHITE); background=rounded(accent,16)
            contentDescription="Add task"; setOnClickListener {
                val value=input.text.toString().trim()
                if(value.isEmpty()) { input.error="Enter a task"; return@setOnClickListener }
                val effectiveDate=captureDate ?: when(filter) { "today" -> LocalDate.now(); "tomorrow" -> LocalDate.now().plusDays(1); else -> null }
                if(captureRepeat!="none" && (effectiveDate==null || captureHour==null || (captureRepeat=="custom" && captureDays.isEmpty()))) {
                    input.error="Choose a date, time and repeat days"; return@setOnClickListener
                }
                val dueAt=effectiveDate?.let { day -> if(captureHour==null) day.toString() else day.atTime(captureHour!!,captureMinute ?: 0).toString() }
                val rule=if(captureRepeat=="custom") "custom:${captureDays.sorted().joinToString(",")}" else captureRepeat
                try {
                    TaskiyaData.addTask(this@NiyaOverlayService,value,dueAt=dueAt,recurrence=rule)
                    clearCapture(); showPanel(filter)
                    if(prefs.getBoolean("celebration_enabled",true)) pose(NiyaFrames.HAPPY,900L)
                } catch (_:Exception) { input.error="Could not save task" }
            }
        },LinearLayout.LayoutParams(dp(46),dp(46)).apply { setMargins(0,0,dp(2),0) })
        container.addView(inputRow)
        container.addView(space(11))
        container.addView(label("SCHEDULE & REPEAT",11f,true,accent))
        container.addView(space(6))
        fun scheduleChip(value: String,selected: Boolean=false,click: () -> Unit)=TextView(this).apply {
            text=value; textSize=11.5f; typeface=Typeface.create(uiTypeface,Typeface.BOLD); gravity=Gravity.CENTER
            setTextColor(if(selected) Color.WHITE else foreground)
            background=rounded(if(selected) accent else soft,12,if(selected) null else line)
            setOnClickListener { click() }
        }
        val dateRow=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL }
        dateRow.addView(scheduleChip("Today",captureDate==LocalDate.now() || (captureDate==null && filter=="today")) {
            captureDate=LocalDate.now(); showPanel(filter,input.text.toString())
        },LinearLayout.LayoutParams(0,dp(34),1f).apply { marginEnd=dp(5) })
        dateRow.addView(scheduleChip("Tomorrow",captureDate==LocalDate.now().plusDays(1) || (captureDate==null && filter=="tomorrow")) {
            captureDate=LocalDate.now().plusDays(1); showPanel(filter,input.text.toString())
        },LinearLayout.LayoutParams(0,dp(34),1f).apply { marginEnd=dp(5) })
        val dateText=if(captureDate!=null && captureDate!=LocalDate.now() && captureDate!=LocalDate.now().plusDays(1)) captureDate!!.format(DateTimeFormatter.ofPattern("MMM d")) else "Pick date"
        dateRow.addView(scheduleChip(dateText,captureDate!=null && dateText!="Pick date") {
            showDateChoice(filter,input.text.toString())
        },LinearLayout.LayoutParams(0,dp(34),1f))
        container.addView(dateRow)
        container.addView(space(6))
        val detailRow=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL }
        val timeText=if(captureHour==null) "◷  Choose time" else "◷  ${(captureDate ?: LocalDate.now()).atTime(captureHour!!,captureMinute ?: 0).format(DateTimeFormatter.ofPattern("h:mm a"))}"
        detailRow.addView(scheduleChip(timeText,captureHour!=null) {
            showTimeChoice(filter,input.text.toString())
        },LinearLayout.LayoutParams(0,dp(36),1f).apply { marginEnd=dp(6) })
        val repeatText=when(captureRepeat) {
            "daily" -> "Daily"; "weekdays" -> "Mon–Fri"; "weekly" -> "Weekly"; "monthly" -> "Monthly"
            "custom" -> "Custom ${captureDays.sorted().joinToString(",")}"
            else -> "Repeat"
        }
        detailRow.addView(scheduleChip("↻  $repeatText",captureRepeat!="none") {
            val options=arrayOf("Does not repeat","Daily","Mon to Fri","Weekly","Monthly","Custom weekdays")
            val values=arrayOf("none","daily","weekdays","weekly","monthly","custom")
            val selected=values.indexOf(captureRepeat).coerceAtLeast(0)
            showOverlayDialog(AlertDialog.Builder(this@NiyaOverlayService,pickerTheme())
                .setTitle("Repeat task")
                .setSingleChoiceItems(options,selected) { dialog,which ->
                    dialog.dismiss()
                    if(values[which]=="custom") {
                        val days=arrayOf("Mon","Tue","Wed","Thu","Fri","Sat","Sun")
                        val chosen=captureDays.toMutableSet()
                        showOverlayDialog(AlertDialog.Builder(this@NiyaOverlayService,pickerTheme())
                            .setTitle("Choose weekdays")
                            .setMultiChoiceItems(days,BooleanArray(7) { chosen.contains(it+1) }) { _,index,checked ->
                                if(checked) chosen.add(index+1) else chosen.remove(index+1)
                            }
                            .setNegativeButton("Cancel",null)
                            .setPositiveButton("Apply") { _,_ ->
                                if(chosen.isEmpty()) Toast.makeText(this@NiyaOverlayService,"Choose at least one day",Toast.LENGTH_SHORT).show()
                                else { captureDays.clear(); captureDays.addAll(chosen); captureRepeat="custom"; showPanel(filter,input.text.toString()) }
                            }.create())
                    } else { captureRepeat=values[which]; showPanel(filter,input.text.toString()) }
                }.setNegativeButton("Cancel",null).create())
        },LinearLayout.LayoutParams(0,dp(36),1f))
        container.addView(detailRow)
        container.addView(space(11))
        container.addView(label("TASK LIST",11f,true,accent))
        container.addView(space(6))
        val filters=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL }
        for((labelText,value) in listOf("Today" to "today","Tomorrow" to "tomorrow","Main" to "main")) {
            filters.addView(TextView(this).apply {
                text=labelText; textSize=12f; typeface=Typeface.create(uiTypeface,Typeface.BOLD); gravity=Gravity.CENTER
                setTextColor(if(filter==value) Color.WHITE else muted)
                background=rounded(if(filter==value) accent else soft,14,if(filter==value) null else line)
                setOnClickListener { showPanel(value,input.text.toString()) }
            },LinearLayout.LayoutParams(0,dp(35),1f).apply { marginEnd=dp(if(value=="main") 0 else 5) })
        }
        container.addView(filters)
        container.addView(space(13))
        val section=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL; gravity=Gravity.CENTER_VERTICAL }
        section.addView(label(when(filter) { "tomorrow" -> "Tomorrow"; "main" -> "Main tasks"; else -> "Today" },15f,true),LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1f))
        val tasks=TaskiyaData.tasks(this,filter,4)
        section.addView(label("${tasks.size} shown",11f,false,muted))
        container.addView(section)
        container.addView(space(6))
        val list=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL }
        if(tasks.isEmpty()) {
            list.addView(label("All clear · Add a task to get started",12f,false,muted).apply { gravity=Gravity.CENTER; setPadding(dp(10),dp(15),dp(10),dp(15)); background=rounded(soft,15) })
        }
        tasks.forEach { task ->
            val row=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL; gravity=Gravity.CENTER_VERTICAL; setPadding(dp(11),dp(5),dp(10),dp(5)); background=rounded(soft,15) }
            row.addView(label("○",27f,false,accent),LinearLayout.LayoutParams(dp(34),dp(42)))
            val details=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; addView(label(task.title.take(36),13f,true)); if(task.dueAt!=null) addView(label(task.dueAt.take(16).replace('T',' '),10f,false,muted)) }
            row.addView(details,LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1f))
            if(task.priority>=2) row.addView(label("●",13f,false,accent))
            row.setOnClickListener {
                TaskiyaData.complete(this,task.id); showPanel(filter)
                if(prefs.getBoolean("celebration_enabled",true)) pose(NiyaFrames.COMPLETED,900L)
            }
            list.addView(row,LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,dp(54)).apply { bottomMargin=dp(5) })
        }
        container.addView(ScrollView(this).apply { isFillViewport=false; addView(list) },LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,dp(if(tasks.isEmpty()) 44 else (tasks.size*59).coerceAtMost(177))))
        container.addView(space(3))
        container.addView(TextView(this).apply { text="Open DAYNIX  →"; textSize=12f; typeface=Typeface.create(uiTypeface,Typeface.BOLD); setTextColor(accent); gravity=Gravity.CENTER; setOnClickListener { startActivity(Intent(this@NiyaOverlayService,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); clearCapture(); removePanel() } },LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,dp(28)))
        val backdrop=View(this).apply { setBackgroundColor(if(dark) Color.argb(108,0,0,0) else Color.argb(63,25,12,37)); setOnClickListener { clearCapture(); removePanel() } }
        val backdropParams=params(WindowManager.LayoutParams.MATCH_PARENT,WindowManager.LayoutParams.MATCH_PARENT,false)
        val width=(screenWidth-dp(28)).coerceAtMost(dp(360))
        val lp=params(width,WindowManager.LayoutParams.WRAP_CONTENT,true).apply { x=(screenWidth-width)/2; y=(screenHeight/8).coerceAtLeast(dp(36)) }
        try { window.addView(backdrop,backdropParams); panelBackdrop=backdrop; window.addView(container,lp); panel=container }
        catch (_:Exception) { removePanel() }
    }
    private fun showReminder(id: String, title: String) {
        if(!canShow()) return
        removePanel()
        pose(NiyaFrames.REMINDER)
        pet?.alpha=1f
        val dark=isDark()
        val surface=if(dark) Color.rgb(32,24,34) else Color.rgb(255,247,251)
        val foreground=if(dark) Color.rgb(249,239,247) else Color.rgb(33,27,44)
        val accent=Color.rgb(255,124,171)
        val box=LinearLayout(this).apply {
            orientation=LinearLayout.VERTICAL; setPadding(dp(18),dp(16),dp(18),dp(17))
            background=card(surface,26).apply { setStroke(dp(1),if(dark) Color.rgb(95,57,78) else Color.rgb(248,208,225)) }
            elevation=dp(18).toFloat()
        }
        val heading=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL; gravity=Gravity.CENTER_VERTICAL }
        heading.addView(ImageView(this).apply { usePetImage() },LinearLayout.LayoutParams(dp(55),dp(55)))
        heading.addView(TextView(this).apply {
            text="${petName()} · DAYNIX"; textSize=18f; typeface=Typeface.create(uiTypeface,Typeface.BOLD); setTextColor(foreground)
            setPadding(dp(9),0,0,0)
        },LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1f))
        heading.addView(TextView(this).apply {
            text="×"; textSize=24f; gravity=Gravity.CENTER; setTextColor(foreground); contentDescription="Dismiss reminder"
            setOnClickListener { removePanel() }
        },LinearLayout.LayoutParams(dp(36),dp(36)))
        box.addView(heading)
        box.addView(TextView(this).apply {
            text="Your task starts in 10 seconds"; textSize=12f; setTextColor(accent); setPadding(0,dp(10),0,0)
        })
        box.addView(TextView(this).apply {
            text=title; textSize=20f; typeface=Typeface.create(uiTypeface,Typeface.BOLD); setTextColor(foreground)
            setPadding(0,dp(4),0,dp(13))
        })
        val first=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL }
        first.addView(button("View task") { removePanel(); startActivity(Intent(this,MainActivity::class.java).apply {
            flags=Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP; putExtra("task_id",id)
        }) },LinearLayout.LayoutParams(0,dp(43),1f).apply { marginEnd=dp(6) })
        first.addView(button("Mark done") { if(id.isNotEmpty()) TaskiyaData.complete(this,id); removePanel() },LinearLayout.LayoutParams(0,dp(43),1f))
        box.addView(first)
        val second=LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL; setPadding(0,dp(7),0,0) }
        second.addView(button("Snooze 5 min") { if(id.isNotEmpty()) NiyaReminders.snooze(this,id,title); removePanel() },LinearLayout.LayoutParams(0,dp(43),1f).apply { marginEnd=dp(6) })
        second.addView(button("Dismiss") { if(id.isNotEmpty()) NiyaReminders.dismiss(this,id); removePanel() },LinearLayout.LayoutParams(0,dp(43),1f))
        box.addView(second)
        val backdrop=View(this).apply { setBackgroundColor(Color.argb(112,0,0,0)); setOnClickListener { removePanel() } }
        val width=(screenWidth-dp(32)).coerceAtMost(dp(360))
        val lp=params(width,WindowManager.LayoutParams.WRAP_CONTENT,false).apply { x=(screenWidth-width)/2; y=dp(110) }
        try {
            window.addView(backdrop,params(WindowManager.LayoutParams.MATCH_PARENT,WindowManager.LayoutParams.MATCH_PARENT,false)); panelBackdrop=backdrop
            window.addView(box,lp); panel=box
            handler.postDelayed({ if(panel===box) removePanel() },15000)
        } catch (_:Exception) { removePanel() }
    }
    override fun onDestroy() { unregisterReceiver(screenReceiver); removePanel(); handler.removeCallbacksAndMessages(null); pet?.let { try { window.removeView(it) } catch (_:Exception){} }; pet=null; frames?.close(); frames=null; notificationAvatar?.let { if (!it.isRecycled) it.recycle() }; notificationAvatar=null; super.onDestroy() }
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if(prefs.getBoolean("niya_enabled",false) && !prefs.getBoolean("niya_paused",false)) {
            try { showPet() } catch (_:Exception) { }
        }
    }
}


