package com.example.intercom_talkie

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps an intercom session alive while the app is
 * backgrounded or the task is swiped away.
 *
 * Responsibilities:
 *  - Persistent notification with a Stop action.
 *  - Partial wake lock (CPU), Wi-Fi lock (radio) and multicast lock (UDP
 *    beacon reception) while a session is active.
 *  - Own audio-focus listener: a GSM call takes focus away -> notify Dart
 *    (pause); when the call ends focus returns -> notify Dart (resume).
 */
class IntercomService : Service() {

    companion object {
        const val ACTION_START = "com.example.intercom_talkie.START"
        const val ACTION_UPDATE = "com.example.intercom_talkie.UPDATE"
        const val ACTION_STOP = "com.example.intercom_talkie.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        private const val CHANNEL_ID = "intercom_session"
        private const val NOTIFICATION_ID = 42

        @Volatile
        var sessionRunning = false
            private set

        private var wakeLock: PowerManager.WakeLock? = null
        private var wifiLock: WifiManager.WifiLock? = null
        private var multicastLock: WifiManager.MulticastLock? = null
        private var focusRequest: AudioFocusRequest? = null
        private var audioManager: AudioManager? = null

        /**
         * Re-asserts the communication audio setup after a phone call.
         * Safe to call even when the service is not running.
         */
        fun recoverAudio(context: Context) {
            val am =
                context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            try {
                am.mode = AudioManager.MODE_IN_COMMUNICATION
            } catch (_: Exception) {
                // Some devices throw while a call is still tearing down.
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    val devices = am.availableCommunicationDevices
                    val target = devices.firstOrNull {
                        it.type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                            // LE Audio headsets (API 31+, same guard as this block).
                            it.type == android.media.AudioDeviceInfo.TYPE_BLE_HEADSET
                    } ?: devices.firstOrNull {
                        it.type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                            it.type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                            it.type == android.media.AudioDeviceInfo.TYPE_USB_HEADSET
                    }
                    if (target != null) {
                        am.setCommunicationDevice(target)
                    }
                } catch (_: Exception) {
                    // Best effort.
                }
            } else {
                try {
                    if (am.isBluetoothScoOn || am.isBluetoothA2dpOn) {
                        am.startBluetoothSco()
                        am.isBluetoothScoOn = true
                    }
                } catch (_: Exception) {
                    // Best effort.
                }
            }
            // Re-request audio focus so our listener is in the chain again.
            requeueFocusRequest()
        }

        private fun requeueFocusRequest() {
            val am = audioManager ?: return
            val request = focusRequest ?: return
            try {
                am.requestAudioFocus(request)
            } catch (_: Exception) {
                // Ignore.
            }
            try {
                am.mode = AudioManager.MODE_IN_COMMUNICATION
            } catch (_: Exception) {
                // Ignore.
            }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                NativeEvents.post("serviceStopped")
                cleanup()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                val text = intent.getStringExtra(EXTRA_TEXT) ?: return START_STICKY
                updateNotification(text)
                return START_STICKY
            }
            else -> {
                // ACTION_START or a sticky restart.
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Talkie"
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Session active"
                startSession(title, text)
                return START_STICKY
            }
        }
    }

    private fun startSession(title: String, text: String) {
        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            NativeEvents.post("missingPermissions", "RECORD_AUDIO")
            cleanup()
            stopSelf()
            return
        }

        createNotificationChannel()
        val notification = buildNotification(title, text)
        val types = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        } else {
            0
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, types)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            // Retry with the microphone type only: the connectedDevice type
            // has extra runtime prerequisites (e.g. BLUETOOTH_CONNECT) that
            // may not hold on every device.
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            } catch (second: Exception) {
                NativeEvents.post("serviceError", second.message ?: "startForeground failed")
                cleanup()
                stopSelf()
            }
        }

        if (!sessionRunning) {
            sessionRunning = true
            acquireLocks()
            registerFocusListener()
        } else {
            updateNotification(text)
        }
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Talkie session",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps the intercom link alive"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun contentIntent(): PendingIntent {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val safeIntent = intent ?: Intent(this, MainActivity::class.java)
        return PendingIntent.getActivity(
            this,
            0,
            safeIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun stopIntent(): PendingIntent {
        val intent = Intent(this, IntercomService::class.java).apply {
            action = ACTION_STOP
        }
        return PendingIntent.getService(
            this,
            1,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildNotification(title: String, text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_talkie)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(contentIntent())
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "End session",
                stopIntent(),
            )
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        try {
            manager.notify(
                NOTIFICATION_ID,
                buildNotification("Talkie", text),
            )
        } catch (_: Exception) {
            // Ignore.
        }
    }

    private fun acquireLocks() {
        // Every lock is best-effort: a missing permission or a vendor quirk
        // must degrade the session, never crash the process.
        try {
            val power = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "IntercomTalkie:session",
            ).apply { acquire(6 * 60 * 60 * 1000L) }
        } catch (error: Exception) {
            NativeEvents.post("lockError", "wake: ${error.message}")
        }

        try {
            val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            wifiLock = wifi.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "IntercomTalkie:wifi",
            ).apply { acquire() }
        } catch (error: Exception) {
            NativeEvents.post("lockError", "wifi: ${error.message}")
        }

        try {
            val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("IntercomTalkie:beacon").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (error: Exception) {
            // Needs CHANGE_WIFI_MULTICAST_STATE (declared in the manifest);
            // without it beacon reception still works on most hotspot LANs.
            NativeEvents.post("lockError", "multicast: ${error.message}")
        }
    }

    private fun releaseLocks() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
        try {
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wifiLock = null
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    private fun registerFocusListener() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager = am

        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS -> {
                    NativeEvents.post("focusLoss", "permanent")
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
                -> {
                    NativeEvents.post("focusLoss", "transient")
                }
                AudioManager.AUDIOFOCUS_GAIN -> {
                    NativeEvents.post("focusGain")
                }
                else -> {
                    // AUDIOFOCUS_GAIN_TRANSIENT etc. — ignore.
                }
            }
        }

        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener(listener, mainHandler)
                .build()
            focusRequest = request
            try {
                am.requestAudioFocus(request)
            } catch (_: Exception) {
                // Ignore — plugin also manages focus.
            }
        } else {
            @Suppress("DEPRECATION")
            try {
                am.requestAudioFocus(
                    listener,
                    AudioManager.STREAM_VOICE_CALL,
                    AudioManager.AUDIOFOCUS_GAIN,
                )
            } catch (_: Exception) {
                // Ignore — plugin also manages focus.
            }
        }
    }

    private fun abandonFocus() {
        val am = audioManager
        val request = focusRequest
        if (am != null && request != null) {
            try {
                am.abandonAudioFocusRequest(request)
            } catch (_: Exception) {
            }
        }
        audioManager = null
        focusRequest = null
    }

    private fun cleanup() {
        sessionRunning = false
        abandonFocus()
        releaseLocks()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The service keeps running (stopWithTask=false). Nudge it awake in
        // case an aggressive OEM stopped it. Best effort only.
        if (sessionRunning) {
            try {
                val restartIntent = Intent(this, IntercomService::class.java).apply {
                    action = ACTION_START
                }
                val flags =
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                val pending = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    PendingIntent.getForegroundService(this, 2, restartIntent, flags)
                } else {
                    PendingIntent.getService(this, 2, restartIntent, flags)
                }
                val alarmManager = getSystemService(ALARM_SERVICE) as AlarmManager
                alarmManager.set(
                    AlarmManager.ELAPSED_REALTIME,
                    SystemClock.elapsedRealtime() + 800,
                    pending,
                )
            } catch (_: Exception) {
                // Ignore.
            }
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        cleanup()
        super.onDestroy()
    }
}
