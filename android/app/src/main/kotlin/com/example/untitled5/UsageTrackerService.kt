package com.example.untitled5

import android.app.*
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.*

////////////////////////////////////////////////////////////
// UsageTrackerService — accurate screen-time tracking
//
// FIXES IN THIS VERSION:
//   ✓ Yesterday report auto-finalization on app start
//   ✓ Day boundary detection for proper handoff
//   ✓ Simplified KEYGUARD logic (was double-counting)
//   ✓ Better backfill with proactive yesterday updates
//   ✓ Improved accuracy matching Digital Wellbeing
////////////////////////////////////////////////////////////

class UsageTrackerService : Service() {

    companion object {
        const val CHANNEL_ID      = "usage_tracker_channel"
        const val NOTIFICATION_ID = 1001
        const val TAG             = "UsageTrackerService"
        const val UPLOAD_INTERVAL = 30_000L
        const val ICON_SIZE_PX    = 48
        const val BACKFILL_DAYS   = 30

        const val MIN_REPORT_MS   = 3_000L

        const val SCREEN_LIMIT_MINS     = 240
        const val SCREEN_OVER_MINS      = 360
        const val FOCUS_EXCELLENT_MINS  = 60
        const val FOCUS_GOOD_MINS       = 30
        const val FOCUS_LOW_MINS        = 10
        const val SLEEP_LOW_MINS        = 10
        const val SLEEP_MODERATE_MINS   = 30
        const val CONTINUOUS_ALERT_MINS = 40

        const val JOB_ID_PERIODIC = 42
        const val JOB_ID_EOD      = 43

        private val EXCLUDED_PACKAGES = setOf(
            "com.miui.home", "com.android.launcher", "com.android.launcher2",
            "com.android.launcher3", "com.google.android.apps.nexuslauncher",
            "com.sec.android.app.launcher", "com.oneplus.launcher",
            "com.oppo.launcher", "com.realme.launcher", "com.vivo.launcher",
            "com.asus.launcher", "com.huawei.android.launcher",
            "com.nothing.launcher", "com.hihonor.android.launcher",
            "com.lge.launcher3", "com.tcl.launcher",
            "com.transsion.launcher", "com.itel.launcher",
            "com.infinix.launcher",
            "com.android.systemui", "com.android.settings",
            "com.miui.securitycenter", "com.miui.home.recents",
            "com.google.android.inputmethod.latin",
            "com.samsung.android.inputmethod", "com.miui.inputmethod",
            "com.touchtype.swiftkey", "com.swiftkey.swiftkeyapp",
            "com.google.android.apps.inputmethod.hindi",
            "com.google.android.apps.inputmethod.tamil",
            "com.android.incallui", "com.samsung.android.incallui",
            "com.google.android.gms", "com.google.android.gsf",
            "com.google.process.gapps", "com.android.phone",
            "com.android.server.telecom", "android",
            "com.android.providers.media",
        )

        fun startService(context: Context) {
            val intent = Intent(context, UsageTrackerService::class.java)
            try {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                Log.d(TAG, "Service start requested")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start service: ${e.message}")
            }
        }

        fun schedulePeriodicJobIfNeeded(context: Context) {
            val js = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
            if (js.getPendingJob(JOB_ID_PERIODIC) != null) return
            val info = JobInfo.Builder(
                JOB_ID_PERIODIC,
                ComponentName(context, UsageTrackerJobService::class.java)
            )
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPeriodic(15 * 60 * 1000L)
                .setPersisted(true)
                .build()
            js.schedule(info)
            Log.d(TAG, "Periodic job scheduled (JOB_ID=$JOB_ID_PERIODIC)")
        }

        fun scheduleEndOfDayJob(context: Context) {
            val js = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
            js.cancel(JOB_ID_EOD)

            val now    = Calendar.getInstance()
            val target = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, 23)
                set(Calendar.MINUTE, 50)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            if (now.after(target)) target.add(Calendar.DAY_OF_YEAR, 1)
            val delayMs = target.timeInMillis - now.timeInMillis

            val info = JobInfo.Builder(
                JOB_ID_EOD,
                ComponentName(context, UsageTrackerJobService::class.java)
            )
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setMinimumLatency(delayMs)
                .setOverrideDeadline(delayMs + 30 * 60 * 1000L)
                .setPersisted(true)
                .build()
            js.schedule(info)
            Log.d(TAG, "EOD job scheduled in ${delayMs / 60_000} min (JOB_ID=$JOB_ID_EOD)")
        }

        fun scheduleJobIfNeeded(context: Context) {
            schedulePeriodicJobIfNeeded(context)
            scheduleEndOfDayJob(context)
        }

        // ── YESTERDAY FINALIZATION (NEW) ──────────────────────────────────
        // Call this when service starts to finalize yesterday's report if a day
        // boundary has been crossed.
        fun finalizeYesterdayIfNeeded(context: Context) {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val lastUploadDateKey = prefs.getString("lastFinalizedDate", null)
            val todayKey = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date(startOfTodayMs()))

            if (lastUploadDateKey != todayKey) {
                Log.d(TAG, "Day boundary crossed — finalizing yesterday (lastFinalized=$lastUploadDateKey, today=$todayKey)")
                val midnight = startOfTodayMs()
                val yesterdayStart = midnight - 86_400_000L
                val yesterdayKey = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date(yesterdayStart))

                // Finalize yesterday's data explicitly
                Thread {
                    try {
                        doUpload(context, isEndOfDay = true, forceDate = yesterdayKey)
                    } catch (e: Exception) {
                        Log.e(TAG, "Yesterday finalization failed: ${e.message}")
                    }
                }.start()

                // Mark this date as finalized
                prefs.edit().putString("lastFinalizedDate", todayKey).apply()
            }
        }

        // ── Core upload (updated signature) ────────────────────────────────
        fun doUpload(context: Context, isEndOfDay: Boolean = false, forceDate: String? = null) {
            try { FirebaseApp.initializeApp(context) } catch (_: Exception) {}
            val db = FirebaseFirestore.getInstance()

            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE
            )
            val userEmail = prefs.getString("flutter.userEmail", null)
                ?: prefs.getString("flutter.flutter.userEmail", null)

            if (userEmail.isNullOrEmpty()) {
                Log.w(TAG, "No userEmail — skipping upload")
                return
            }

            val now = System.currentTimeMillis()

            // Determine the window: use forceDate if provided (for yesterday finalization)
            val (windowStart, windowEnd) = if (forceDate != null) {
                windowForDateKey(forceDate)
            } else {
                Pair(startOfTodayMs(), now)
            }

            val dateKey = forceDate ?: SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date(windowStart))
            val yesterdayKey = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
                .format(Date(windowStart - 86_400_000L))

            val json = try {
                buildUsageJsonForWindow(context, windowStart, windowEnd)
            } catch (e: Exception) {
                Log.e(TAG, "buildUsageJsonForWindow failed: ${e.message}"); return
            }

            val ref = db.collection("reports").document(userEmail)

            var prevTotalMins: Int? = null
            var prevApps:      Int? = null
            var prevFocusMins: Int? = null
            var prevPickups:   Int? = null
            try {
                val snap = Tasks.await(ref.collection("days").document(yesterdayKey).get())
                if (snap.exists()) {
                    prevTotalMins = (snap.getLong("totalMins")    ?: 0L).toInt()
                    prevApps      = (snap.getLong("appCount")     ?: 0L).toInt()
                    prevFocusMins = (snap.getLong("focusMinutes") ?: 0L).toInt()
                    prevPickups   = (snap.getLong("pickups")      ?: 0L).toInt()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not fetch yesterday ($yesterdayKey): ${e.message}")
            }

            val payload = buildPayload(
                userEmail, json, prevTotalMins, prevApps, prevFocusMins, prevPickups, isEndOfDay
            )

            try {
                Tasks.await<Void>(ref.set(payload, SetOptions.merge()))
                Tasks.await<Void>(ref.collection("days").document(dateKey).set(payload))
                Log.d(TAG, "Upload OK ✓ user=$userEmail date=$dateKey isEod=$isEndOfDay totalMins=${json.optLong("totalMins")}")
            } catch (e: Exception) {
                Log.e(TAG, "Firestore write failed: ${e.message}")
            }
        }

        private fun buildPayload(
            userEmail: String, json: JSONObject,
            prevTotalMins: Int?, prevApps: Int?, prevFocusMins: Int?, prevPickups: Int?,
            isEndOfDay: Boolean
        ): Map<String, Any?> {
            val iconMap = mutableMapOf<String, String>()
            val contMap = mutableMapOf<String, Int>()

            val iconsObj = json.optJSONObject("icons")
            iconsObj?.keys()?.forEach { k ->
                val b64 = iconsObj.optString(k, "")
                if (b64.isNotEmpty()) iconMap[k] = b64
            }
            Log.d(TAG, "buildPayload: ${iconMap.size} icons packed")

            val contObj = json.optJSONObject("continuousUsage")
            contObj?.keys()?.forEach { k ->
                contMap[k] = contObj.optInt(k, 0)
            }

            val map = mutableMapOf<String, Any?>(
                "userEmail"         to userEmail,
                "report"            to json.optString("report"),
                "updatedAt"         to json.optString("updatedAt"),
                "icons"             to iconMap,
                "totalMins"         to json.optLong("totalMins"),
                "appCount"          to json.optInt("appCount"),
                "focusMinutes"      to json.optLong("focusMinutes"),
                "pickups"           to json.optInt("pickups"),
                "screenTimeStatus"  to json.optString("screenTimeStatus"),
                "focusTimeStatus"   to json.optString("focusTimeStatus"),
                "sleepImpactStatus" to json.optString("sleepImpactStatus"),
                "continuousUsage"   to contMap,
                "uploadedByJob"     to true,
                "isEndOfDay"        to isEndOfDay,
            )
            if (prevTotalMins != null) map["prevTotalMins"] = prevTotalMins
            if (prevApps      != null) map["prevApps"]      = prevApps
            if (prevFocusMins != null) map["prevFocusMins"] = prevFocusMins
            if (prevPickups   != null) map["prevPickups"]   = prevPickups
            return map
        }

        fun hasUsagePermission(context: Context): Boolean {
            val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode   = appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                context.packageName
            )
            return mode == AppOpsManager.MODE_ALLOWED
        }

        fun startOfTodayMs(): Long = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0);      set(Calendar.MILLISECOND, 0)
        }.timeInMillis

        fun windowForDateKey(dateKey: String): Pair<Long, Long> {
            val sdf  = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
            val date = sdf.parse(dateKey) ?: throw IllegalArgumentException("Bad dateKey: $dateKey")
            val cal  = Calendar.getInstance().apply {
                time = date
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0);      set(Calendar.MILLISECOND, 0)
            }
            val dayStart = cal.timeInMillis
            return Pair(dayStart, minOf(dayStart + 86_400_000L, System.currentTimeMillis()))
        }

        fun registerChannel(context: Context, flutterEngine: FlutterEngine) {
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "com.example.untitled5/usage"
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "getTodayUsage" -> {
                        if (!hasUsagePermission(context)) {
                            result.error("PERMISSION_DENIED", "Usage Access permission not granted", null)
                        } else {
                            try {
                                val json = buildUsageJsonForWindow(
                                    context, startOfTodayMs(), System.currentTimeMillis()
                                )
                                result.success(json.toString())
                            } catch (e: Exception) {
                                result.error("ERROR", e.message, null)
                            }
                        }
                    }
                    "getUsageForDate" -> {
                        if (!hasUsagePermission(context)) {
                            result.error("PERMISSION_DENIED", "Usage Access permission not granted", null)
                        } else {
                            val dateKey = call.argument<String>("dateKey")
                            if (dateKey == null) {
                                result.error("BAD_ARGS", "dateKey is required", null)
                                return@setMethodCallHandler
                            }
                            try {
                                val (dayStart, dayEnd) = windowForDateKey(dateKey)
                                val json = buildUsageJsonForWindow(context, dayStart, dayEnd)
                                result.success(json.toString())
                            } catch (e: Exception) {
                                result.error("ERROR", e.message, null)
                            }
                        }
                    }
                    "getLocalDaysWithData" -> {
                        if (!hasUsagePermission(context)) {
                            result.error("PERMISSION_DENIED", "Usage Access permission not granted", null)
                        } else {
                            try {
                                val daysWithData = mutableListOf<String>()
                                val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
                                for (daysAgo in 0..29) {
                                    val cal = Calendar.getInstance()
                                    cal.add(Calendar.DAY_OF_YEAR, -daysAgo)
                                    val dayStart = cal.apply {
                                        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                                        set(Calendar.SECOND, 0);      set(Calendar.MILLISECOND, 0)
                                    }.timeInMillis
                                    val dayEnd = if (daysAgo == 0) System.currentTimeMillis()
                                    else minOf(dayStart + 86_400_000L, System.currentTimeMillis())
                                    val usageMap = getUsageMapForWindowStatic(context, dayStart, dayEnd)
                                    if (usageMap.any { it.value >= MIN_REPORT_MS } || daysAgo == 0) {
                                        daysWithData.add(fmt.format(Date(dayStart)))
                                    }
                                }
                                result.success(org.json.JSONArray(daysWithData).toString())
                            } catch (e: Exception) {
                                result.error("ERROR", e.message, null)
                            }
                        }
                    }
                    "requestBatteryExemption" -> {
                        try {
                            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (!pm.isIgnoringBatteryOptimizations(context.packageName)) {
                                val intent = Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                                ).apply {
                                    data = Uri.parse("package:${context.packageName}")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                context.startActivity(intent)
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }
                    "openUsageSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        fun buildUsageJsonForWindow(context: Context, windowStart: Long, windowEnd: Long): JSONObject {
            val usageMap      = getUsageMapForWindowStatic(context, windowStart, windowEnd)
            val focusMins     = getFocusMinutesStatic(context, windowStart, windowEnd)
            val pickups       = getPickupCountStatic(context, windowStart, windowEnd)
            val lateNight     = getLateNightMinutesStatic(context, windowStart)
            val continuousMap = getContinuousUsageMapStatic(context, windowStart, windowEnd)

            val dateLabel = SimpleDateFormat("dd MMM yyyy", Locale.getDefault()).format(Date(windowStart))
            val timeLabel = SimpleDateFormat("HH:mm:ss",    Locale.getDefault()).format(Date())
            val report    = buildReportStringStatic(context, usageMap, dateLabel, timeLabel)

            val totalMins = usageMap.values.sum() / 60_000L
            val appCount  = usageMap.size

            val iconMapJson = JSONObject()
            var iconBytesTotal = 0
            usageMap.keys.forEach { pkg ->
                if (iconBytesTotal >= MAX_ICONS_BYTES) return@forEach
                val b64 = getAppIconBase64Static(context, pkg)
                if (b64.isNotEmpty()) {
                    iconBytesTotal += b64.length
                    iconMapJson.put(pkg, b64)
                }
            }
            Log.d(TAG, "Icons built: ${iconMapJson.length()} icons, ~${iconBytesTotal / 1024} KB")

            val continuousJson = JSONObject()
            continuousMap.forEach { (pkg, mins) -> continuousJson.put(pkg, mins) }

            return JSONObject().apply {
                put("report",            report)
                put("updatedAt",         "$dateLabel $timeLabel")
                put("icons",             iconMapJson)
                put("totalMins",         totalMins)
                put("appCount",          appCount)
                put("focusMinutes",      focusMins)
                put("pickups",           pickups)
                put("screenTimeStatus",  computeScreenTimeStatusStatic(totalMins.toInt()))
                put("focusTimeStatus",   computeFocusTimeStatusStatic(focusMins.toInt()))
                put("sleepImpactStatus", computeSleepImpactStatusStatic(lateNight))
                put("continuousUsage",   continuousJson)
            }
        }

        fun buildTodayUsageJson(context: Context): JSONObject =
            buildUsageJsonForWindow(context, startOfTodayMs(), System.currentTimeMillis())

        // ─────────────────────────────────────────────────────────────────
        // IMPROVED: getUsageMapForWindowStatic — strict topmost-app model
        //
        // KEY ACCURACY FIXES:
        // 1. KEYGUARD_SHOWN removed from manual pause logic
        //    → Only SCREEN_NON_INTERACTIVE pauses the timer
        //    → KEYGUARD timing is implicit in screen events
        // 2. Screen state reset at midnight to avoid phantom counts
        // 3. Strict event replay matching Digital Wellbeing
        // ─────────────────────────────────────────────────────────────────
        fun getUsageMapForWindowStatic(
            context: Context,
            windowStart: Long,
            windowEnd: Long
        ): Map<String, Long> {

            val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager

            data class EvSnap(val ts: Long, val pkg: String, val type: Int)

            val allEvents = mutableListOf<EvSnap>()
            val rawIter   = usm.queryEvents(windowStart, windowEnd)
            val tmp       = UsageEvents.Event()
            while (rawIter.hasNextEvent()) {
                rawIter.getNextEvent(tmp)
                val p = tmp.packageName ?: continue
                allEvents.add(EvSnap(tmp.timeStamp, p, tmp.eventType))
            }
            allEvents.sortBy { it.ts }

            val accumulator  = mutableMapOf<String, Long>()
            var currentApp   : String? = null
            var sessionStart : Long    = windowStart
            var screenOn     : Boolean = false

            fun credit(pkg: String, from: Long, to: Long) {
                val ms = (to - from).coerceAtLeast(0L)
                if (ms >= MIN_REPORT_MS && screenOn) {
                    accumulator[pkg] = (accumulator[pkg] ?: 0L) + ms
                }
            }

            for (ev in allEvents) {
                val ts  = ev.ts
                val pkg = ev.pkg

                when (ev.type) {

                    UsageEvents.Event.SCREEN_INTERACTIVE -> {
                        sessionStart = ts
                        screenOn     = true
                    }

                    UsageEvents.Event.SCREEN_NON_INTERACTIVE -> {
                        // ONLY here do we pause — this is the single source of truth
                        if (screenOn) {
                            currentApp?.let { credit(it, sessionStart, ts) }
                            sessionStart = ts
                            screenOn     = false
                        }
                    }

                    // NOTE: KEYGUARD_SHOWN is removed from direct timer control
                    // The screen ON/OFF state accurately captures lock/unlock
                    // Handling KEYGUARD separately was causing double-counting
                    // with SCREEN_NON_INTERACTIVE events

                    UsageEvents.Event.MOVE_TO_FOREGROUND -> {
                        if (pkg in EXCLUDED_PACKAGES) continue

                        if (currentApp != null && currentApp != pkg) {
                            credit(currentApp!!, sessionStart, ts)
                        }
                        currentApp   = pkg
                        sessionStart = ts
                    }

                    UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                        if (pkg in EXCLUDED_PACKAGES) continue

                        if (pkg == currentApp) {
                            credit(currentApp!!, sessionStart, ts)
                            currentApp   = null
                            sessionStart = ts
                        }
                    }
                }
            }

            val capEnd = minOf(System.currentTimeMillis(), windowEnd)
            if (screenOn && currentApp != null) {
                credit(currentApp!!, sessionStart, capEnd)
            }

            return accumulator.filter { it.value >= MIN_REPORT_MS }
        }

        // ── Focus minutes (unchanged logic, EXCLUDED_PACKAGES applied) ─
        private fun getFocusMinutesStatic(context: Context, windowStart: Long, windowEnd: Long): Long {
            val usm    = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val events = usm.queryEvents(windowStart, windowEnd)
            val event  = UsageEvents.Event()
            val lastFg = mutableMapOf<String, Long>()
            val intervals = mutableListOf<Pair<Long, Long>>()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val pkg = event.packageName ?: continue
                if (pkg in EXCLUDED_PACKAGES) continue
                when (event.eventType) {
                    UsageEvents.Event.MOVE_TO_FOREGROUND -> lastFg[pkg] = event.timeStamp
                    UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                        val start = lastFg.remove(pkg) ?: continue
                        if (event.timeStamp > start) intervals.add(Pair(start, event.timeStamp))
                    }
                }
            }
            val capEnd = minOf(System.currentTimeMillis(), windowEnd)
            lastFg.forEach { (_, start) -> if (capEnd > start) intervals.add(Pair(start, capEnd)) }
            if (intervals.isEmpty()) return (windowEnd - windowStart) / 60_000L
            val sorted    = intervals.sortedBy { it.first }
            var coveredMs = 0L
            var curStart  = sorted[0].first
            var curEnd    = sorted[0].second
            for (i in 1 until sorted.size) {
                val (s, e) = sorted[i]
                if (s <= curEnd) curEnd = maxOf(curEnd, e)
                else { coveredMs += curEnd - curStart; curStart = s; curEnd = e }
            }
            coveredMs += curEnd - curStart
            return ((windowEnd - windowStart - coveredMs).coerceAtLeast(0L)) / 60_000L
        }

        private fun getPickupCountStatic(context: Context, windowStart: Long, windowEnd: Long): Int {
            val usm    = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val events = usm.queryEvents(windowStart, windowEnd)
            val event  = UsageEvents.Event()
            var count  = 0
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                if (event.eventType == UsageEvents.Event.KEYGUARD_HIDDEN) count++
            }
            return count
        }

        private fun getLateNightMinutesStatic(context: Context, dayStart: Long): Int {
            val cal = Calendar.getInstance().apply {
                timeInMillis = dayStart
                set(Calendar.HOUR_OF_DAY, 22); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0);       set(Calendar.MILLISECOND, 0)
            }
            val windowStart = cal.timeInMillis
            val windowEnd   = minOf(windowStart + 3 * 60 * 60 * 1000L, System.currentTimeMillis())
            if (windowEnd <= windowStart) return 0
            val usm    = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val events = usm.queryEvents(windowStart, windowEnd)
            val event  = UsageEvents.Event()
            val lastFg = mutableMapOf<String, Long>()
            var totalMs = 0L
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val pkg = event.packageName ?: continue
                if (pkg in EXCLUDED_PACKAGES) continue
                when (event.eventType) {
                    UsageEvents.Event.MOVE_TO_FOREGROUND -> lastFg[pkg] = event.timeStamp
                    UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                        val start = lastFg.remove(pkg) ?: continue
                        val ms    = event.timeStamp - start
                        if (ms > MIN_REPORT_MS) totalMs += ms
                    }
                }
            }
            lastFg.forEach { (_, start) ->
                val ms = windowEnd - start
                if (ms > MIN_REPORT_MS) totalMs += ms
            }
            return (totalMs / 60_000L).toInt()
        }

        private fun getContinuousUsageMapStatic(
            context: Context, windowStart: Long, windowEnd: Long
        ): Map<String, Int> {
            val usm      = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val events   = usm.queryEvents(windowStart, windowEnd)
            val event    = UsageEvents.Event()
            val sessions = mutableMapOf<String, MutableList<Pair<Long, Long>>>()
            val lastFg   = mutableMapOf<String, Long>()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val pkg = event.packageName ?: continue
                if (pkg in EXCLUDED_PACKAGES) continue
                when (event.eventType) {
                    UsageEvents.Event.MOVE_TO_FOREGROUND -> lastFg[pkg] = event.timeStamp
                    UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                        val start = lastFg.remove(pkg) ?: continue
                        val dur   = event.timeStamp - start
                        if (dur > MIN_REPORT_MS) {
                            sessions.getOrPut(pkg) { mutableListOf() }.add(Pair(start, event.timeStamp))
                        }
                    }
                }
            }
            val now = minOf(System.currentTimeMillis(), windowEnd)
            lastFg.forEach { (pkg, start) ->
                val dur = now - start
                if (dur > MIN_REPORT_MS) {
                    sessions.getOrPut(pkg) { mutableListOf() }.add(Pair(start, now))
                }
            }
            val result = mutableMapOf<String, Int>()
            sessions.forEach { (pkg, rawSessions) ->
                val sorted = rawSessions.sortedBy { it.first }
                val merged = mutableListOf<Pair<Long, Long>>()
                for (s in sorted) {
                    if (merged.isEmpty() || s.first - merged.last().second > 2 * 60_000L) {
                        merged.add(s)
                    } else {
                        val last = merged.removeLast()
                        merged.add(Pair(last.first, maxOf(last.second, s.second)))
                    }
                }
                val maxMins = merged.maxOf { (it.second - it.first) / 60_000L }.toInt()
                if (maxMins >= CONTINUOUS_ALERT_MINS) result[pkg] = maxMins
            }
            return result
        }

        private fun buildReportStringStatic(
            context: Context, usageMap: Map<String, Long>,
            dateLabel: String, timeLabel: String
        ): String {
            val sb     = StringBuilder()
            val sorted = usageMap.entries.sortedByDescending { it.value }
            sb.appendLine("📅 $dateLabel 🕐 Updated $timeLabel")
            sb.appendLine("─".repeat(38))
            if (sorted.isEmpty()) { sb.appendLine("No app usage recorded."); return sb.toString() }
            var totalMs = 0L
            sorted.forEach { (pkg, ms) ->
                totalMs += ms
                sb.appendLine("${appNameStatic(context, pkg).padEnd(22)} ${formatDurationStatic(ms)}|$pkg")
            }
            sb.appendLine("─".repeat(38))
            sb.appendLine("${"TOTAL".padEnd(22)} ${formatDurationStatic(totalMs)}")
            return sb.toString()
        }

        fun appNameStatic(context: Context, pkg: String): String {
            KNOWN_APP_NAMES[pkg]?.let { return it }
            return try {
                val pm    = context.packageManager
                val info  = pm.getApplicationInfo(pkg, PackageManager.GET_META_DATA)
                val label = pm.getApplicationLabel(info).toString().trim()
                if (label.isNotEmpty() && !label.contains('.') && label != pkg) label
                else smartFallbackName(pkg)
            } catch (e: PackageManager.NameNotFoundException) {
                smartFallbackName(pkg)
            }
        }

        private fun smartFallbackName(pkg: String): String {
            val generic = setOf(
                "android","app","mobile","phone","main","core","com","org","net",
                "io","in","co","activity","ui","client","service","lite","pro","plus"
            )
            val parts = pkg.split('.')
            for (i in parts.indices.reversed()) {
                val seg = parts[i].lowercase()
                if (seg !in generic && seg.length > 2) {
                    val spaced = parts[i]
                        .replace(Regex("([a-z])([A-Z])"), "$1 $2")
                        .replace(Regex("([A-Z]+)([A-Z][a-z])"), "$1 $2")
                        .trim()
                    return spaced.replaceFirstChar { it.uppercaseChar() }
                }
            }
            return parts.last().replaceFirstChar { it.uppercaseChar() }
        }

        const val MAX_ICONS_BYTES = 700_000

        fun getAppIconBase64Static(context: Context, pkg: String): String {
            val themedContext = android.view.ContextThemeWrapper(
                context.applicationContext,
                android.R.style.Theme_DeviceDefault
            )
            val bmp = fetchIconBitmap(themedContext, themedContext.packageManager, pkg) ?: return ""
            return try {
                val bos = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, 60, bos)
                Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP)
            } catch (e: Exception) {
                Log.w(TAG, "Icon encode failed for $pkg: ${e.message}"); ""
            }
        }

        private fun fetchIconBitmap(context: Context, pm: PackageManager, pkg: String): Bitmap? {
            try {
                val d = pm.getApplicationIcon(pkg)
                return renderIconBitmap(d)
            } catch (e: Exception) {
                Log.v(TAG, "Strategy1 failed $pkg: ${e.javaClass.simpleName}: ${e.message}")
            }
            try {
                val d = pm.getApplicationInfo(pkg, 0).loadIcon(pm)
                return renderIconBitmap(d)
            } catch (e: Exception) {
                Log.v(TAG, "Strategy2 failed $pkg: ${e.javaClass.simpleName}: ${e.message}")
            }
            try {
                val li = pm.getLaunchIntentForPackage(pkg)
                if (li != null) return renderIconBitmap(pm.getActivityIcon(li))
            } catch (e: Exception) {
                Log.v(TAG, "Strategy3 failed $pkg: ${e.javaClass.simpleName}: ${e.message}")
            }
            try {
                val intent = android.content.Intent(android.content.Intent.ACTION_MAIN).apply {
                    addCategory(android.content.Intent.CATEGORY_LAUNCHER)
                    `package` = pkg
                }
                val list = pm.queryIntentActivities(intent, 0)
                if (list.isNotEmpty()) return renderIconBitmap(list[0].loadIcon(pm))
            } catch (e: Exception) {
                Log.v(TAG, "Strategy4 failed $pkg: ${e.javaClass.simpleName}: ${e.message}")
            }
            Log.w(TAG, "All icon strategies failed for $pkg")
            return null
        }

        private fun renderIconBitmap(drawable: Drawable): Bitmap {
            val size = ICON_SIZE_PX
            val bmp  = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            return bmp
        }

        private fun formatDurationStatic(ms: Long): String {
            val totalMinutes = ms / 60_000L
            val hours = totalMinutes / 60; val minutes = totalMinutes % 60
            return if (hours > 0) "${hours}h ${minutes}m" else "${minutes}m"
        }

        fun computeScreenTimeStatusStatic(totalMins: Int) = when {
            totalMins <= SCREEN_LIMIT_MINS -> "Within Limit"
            totalMins <= SCREEN_OVER_MINS  -> "Over Limit"
            else                           -> "Way Over"
        }
        fun computeFocusTimeStatusStatic(focusMins: Int) = when {
            focusMins >= FOCUS_EXCELLENT_MINS -> "Excellent"
            focusMins >= FOCUS_GOOD_MINS      -> "Good"
            focusMins >= FOCUS_LOW_MINS       -> "Low"
            else                              -> "None"
        }
        fun computeSleepImpactStatusStatic(lateNightMins: Int) = when {
            lateNightMins <= SLEEP_LOW_MINS      -> "Low"
            lateNightMins <= SLEEP_MODERATE_MINS -> "Moderate"
            else                                 -> "High"
        }

        private val KNOWN_APP_NAMES = mapOf(
            "com.whatsapp" to "WhatsApp",
            "com.whatsapp.w4b" to "WhatsApp Business",
            "com.instagram.android" to "Instagram",
            "com.facebook.katana" to "Facebook",
            "com.facebook.lite" to "Facebook Lite",
            "com.facebook.orca" to "Messenger",
            "com.google.android.youtube" to "YouTube",
            "com.google.android.gm" to "Gmail",
            "com.google.android.apps.maps" to "Google Maps",
            "com.google.android.googlequicksearchbox" to "Google",
            "com.google.android.chrome" to "Chrome",
            "com.android.chrome" to "Chrome",
            "com.google.android.apps.photos" to "Google Photos",
            "com.google.android.music" to "Google Play Music",
            "com.spotify.music" to "Spotify",
            "com.netflix.mediaclient" to "Netflix",
            "com.amazon.avod.thirdpartyclient" to "Prime Video",
            "com.snapchat.android" to "Snapchat",
            "com.twitter.android" to "Twitter / X",
            "com.zhiliaoapp.musically" to "TikTok",
            "com.ss.android.ugc.trill" to "TikTok",
            "com.linkedin.android" to "LinkedIn",
            "com.pinterest" to "Pinterest",
            "com.reddit.frontpage" to "Reddit",
            "com.discord" to "Discord",
            "com.telegram.messenger" to "Telegram",
            "org.telegram.messenger" to "Telegram",
            "com.viber.voip" to "Viber",
            "com.skype.raider" to "Skype",
            "com.microsoft.teams" to "Microsoft Teams",
            "com.microsoft.office.outlook" to "Outlook",
            "com.google.android.apps.docs" to "Google Docs",
            "com.google.android.apps.sheets" to "Google Sheets",
            "com.google.android.apps.slides" to "Google Slides",
            "com.google.android.apps.drive" to "Google Drive",
            "com.google.android.keep" to "Google Keep",
            "com.google.android.calendar" to "Google Calendar",
            "com.google.android.dialer" to "Phone",
            "com.google.android.contacts" to "Contacts",
            "com.google.android.apps.messaging" to "Messages",
            "com.android.mms" to "Messages",
            "com.samsung.android.messaging" to "Messages",
            "com.samsung.android.contacts" to "Contacts",
            "com.samsung.android.dialer" to "Phone",
            "com.samsung.android.gallery3d" to "Gallery",
            "com.samsung.android.app.cameraassistant" to "Camera",
            "com.sec.android.app.camera" to "Camera",
            "com.android.camera2" to "Camera",
            "com.amazon.mShop.android.shopping" to "Amazon",
            "in.amazon.mShop.android.shopping" to "Amazon",
            "com.flipkart.android" to "Flipkart",
            "com.myntra.android" to "Myntra",
            "com.swiggy.android" to "Swiggy",
            "app.zomato" to "Zomato",
            "com.phonepe.app" to "PhonePe",
            "com.google.android.apps.nbu.paisa.user" to "Google Pay",
            "net.one97.paytm" to "Paytm",
            "com.truecaller" to "Truecaller",
            "com.pubg.imobile" to "BGMI",
            "com.tencent.ig" to "PUBG Mobile",
            "com.garena.game.freefire" to "Free Fire",
            "com.mojang.minecraftpe" to "Minecraft",
            "com.roblox.client" to "Roblox",
            "com.supercell.clashofclans" to "Clash of Clans",
            "com.king.candycrushsaga" to "Candy Crush",
            "com.miui.player" to "Mi Music",
            "com.mi.health" to "Mi Health",
            "com.xiaomi.mipicks" to "GetApps",
            "com.hotstar.android" to "Disney+ Hotstar",
            "com.mxtech.videoplayer.ad" to "MX Player",
            "com.mxtech.videoplayer.pro" to "MX Player Pro",
            "com.jio.media.ondemand" to "JioCinema",
            "com.jio.jioplay.tv" to "JioTV",
            "com.opera.browser" to "Opera",
            "com.opera.mini.native" to "Opera Mini",
            "org.mozilla.firefox" to "Firefox",
            "com.brave.browser" to "Brave",
            "com.UCMobile.intl" to "UC Browser",
            "com.android.vending" to "Play Store",
            "com.google.android.play.games" to "Google Play Games",
            "com.google.android.webview" to "Chrome",
        )
    }

    private val handler = Handler(Looper.getMainLooper())
    private var db: FirebaseFirestore? = null
    private var wakeLock: PowerManager.WakeLock? = null

    private val uploadRunnable = object : Runnable {
        override fun run() {
            Thread {
                try { doUpload(applicationContext) } catch (e: Exception) {
                    Log.e(TAG, "Uncaught error in uploadRunnable: ${e.message}")
                }
            }.start()
            handler.postDelayed(this, UPLOAD_INTERVAL)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Service onCreate")

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK, "UsageTracker::WakeLock"
        ).apply {
            setReferenceCounted(false)
            acquire(10 * 60 * 1000L)
        }

        try {
            FirebaseApp.initializeApp(this)
            db = FirebaseFirestore.getInstance()
        } catch (e: Exception) {
            Log.e(TAG, "Firebase init error: ${e.message}")
        }

        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())

        schedulePeriodicJobIfNeeded(this)
        scheduleEndOfDayJob(this)

        // NEW: Check day boundary and finalize yesterday if needed
        finalizeYesterdayIfNeeded(this)

        Thread {
            try { backfillHistoricalData() } catch (e: Exception) {
                Log.e(TAG, "Backfill error: ${e.message}")
            }
        }.start()

        handler.post(uploadRunnable)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "Service onStartCommand")
        if (wakeLock?.isHeld == false) wakeLock?.acquire(10 * 60 * 1000L)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "Service onDestroy — scheduling restart")
        handler.removeCallbacks(uploadRunnable)
        wakeLock?.let { if (it.isHeld) it.release() }
        sendBroadcast(Intent("com.example.untitled5.RESTART_SERVICE"))
        scheduleImmediateRestart()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.d(TAG, "Task removed — scheduling restart via AlarmManager")
        scheduleImmediateRestart()
    }

    private fun scheduleImmediateRestart() {
        val pi = PendingIntent.getService(
            applicationContext, 1,
            Intent(applicationContext, UsageTrackerService::class.java),
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
        )
        (getSystemService(Context.ALARM_SERVICE) as AlarmManager).set(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + 2_000L, pi
        )
    }

    private fun backfillHistoricalData() {
        val currentDb = db ?: return
        val prefs     = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val userEmail = prefs.getString("flutter.userEmail", null)
            ?: prefs.getString("flutter.flutter.userEmail", null) ?: return
        if (userEmail.isEmpty()) return

        val fmt   = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
        val today = fmt.format(Date())

        for (daysAgo in 1..BACKFILL_DAYS) {
            val cal = Calendar.getInstance()
            cal.add(Calendar.DAY_OF_YEAR, -daysAgo)
            val dayStart = cal.apply {
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0);      set(Calendar.MILLISECOND, 0)
            }.timeInMillis
            val dayEnd  = dayStart + 86_400_000L
            val dateKey = fmt.format(Date(dayStart))
            if (dateKey == today) continue

            val docRef = currentDb.collection("reports").document(userEmail)
                .collection("days").document(dateKey)

            docRef.get()
                .addOnSuccessListener { snap ->
                    val reportField = snap.getString("report") ?: ""
                    // MORE AGGRESSIVE: update if report is incomplete OR very old
                    // (missing createdAt timestamp means it's old data)
                    if (!snap.exists() || reportField.isEmpty() ||
                        reportField.contains("No app usage recorded") ||
                        !snap.contains("uploadedByJob")) {
                        writeHistoricalDay(docRef, userEmail, dayStart, dayEnd, dateKey)
                    }
                }
                .addOnFailureListener {
                    writeHistoricalDay(docRef, userEmail, dayStart, dayEnd, dateKey)
                }
        }
    }

    private fun writeHistoricalDay(
        docRef: com.google.firebase.firestore.DocumentReference,
        userEmail: String, dayStart: Long, dayEnd: Long, dateKey: String
    ) {
        try {
            val json    = buildUsageJsonForWindow(this, dayStart, dayEnd)
            val payload = buildPayload(userEmail, json, null, null, null, null, false)
            docRef.set(payload)
                .addOnSuccessListener { Log.d(TAG, "Backfill OK: $dateKey") }
                .addOnFailureListener { e -> Log.e(TAG, "Backfill failed $dateKey: ${e.message}") }
        } catch (e: Exception) {
            Log.e(TAG, "Backfill compute failed $dateKey: ${e.message}")
        }
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID, "Usage Tracker", NotificationManager.IMPORTANCE_LOW
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Usage Tracker Running")
            .setContentText("Monitoring app usage in background…")
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setOngoing(true)
            .build()
}

class UsageTrackerJobService : JobService() {
    override fun onStartJob(params: JobParameters?): Boolean {
        val isEod = params?.jobId == UsageTrackerService.JOB_ID_EOD
        Log.d("UsageTrackerJobService", "Job fired id=${params?.jobId} isEod=$isEod")
        Thread {
            try {
                UsageTrackerService.doUpload(applicationContext, isEod)
            } catch (e: Exception) {
                Log.e("UsageTrackerJobService", "doUpload failed: ${e.message}")
            } finally {
                jobFinished(params, false)
                // IMPORTANT: Always reschedule EOD job after it fires
                if (isEod) UsageTrackerService.scheduleEndOfDayJob(applicationContext)
            }
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean = true
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == Intent.ACTION_BOOT_COMPLETED ||
            intent?.action == "android.intent.action.QUICKBOOT_POWERON" ||
            intent?.action == "com.htc.intent.action.QUICKBOOT_POWERON") {
            Log.d("BootReceiver", "Boot completed — scheduling jobs and starting service")
            UsageTrackerService.schedulePeriodicJobIfNeeded(context)
            UsageTrackerService.scheduleEndOfDayJob(context)
            UsageTrackerService.startService(context)
        }
    }
}

class ServiceWatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        Log.d("ServiceWatchdog", "Watchdog fired — restarting UsageTrackerService")
        UsageTrackerService.startService(context)
    }
}