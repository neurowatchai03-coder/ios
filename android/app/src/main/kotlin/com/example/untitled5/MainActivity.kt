package com.example.untitled5

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.app.AlarmManager
import android.app.PendingIntent
import android.util.Log
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val TAG = "MainActivity"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        UsageTrackerService.registerChannel(this, flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.untitled5/lifecycle"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "onUserLoggedIn" -> {
                    Log.d(TAG, "onUserLoggedIn — starting service and scheduling watchdog")
                    startTrackerService()
                    scheduleServiceWatchdog()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        startTrackerService()
        scheduleServiceWatchdog()
    }

    private fun startTrackerService() {
        try {
            val intent = Intent(this, UsageTrackerService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
            else startService(intent)
            Log.d(TAG, "startTrackerService() called")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start service: ${e.message}")
        }
    }

    private fun scheduleServiceWatchdog() {
        val pi = PendingIntent.getBroadcast(
            this, 0, Intent(this, ServiceWatchdogReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        (getSystemService(ALARM_SERVICE) as AlarmManager).setRepeating(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + 60_000L,
            15 * 60 * 1000L, pi
        )
        Log.d(TAG, "Service watchdog alarm scheduled")
    }
}