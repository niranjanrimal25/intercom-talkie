package com.example.intercom_talkie

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.WindowManager
import java.io.File
import java.io.FileOutputStream
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val ENGINE_ID = "talkie_engine"
        private const val PICK_MUSIC_REQUEST = 7501
    }

    // Shared music playback + picker plumbing.
    private var musicPlayer: MediaPlayer? = null
    private var pendingMusicPick: MethodChannel.Result? = null

    /**
     * This activity runs on a *cached* FlutterEngine. Swiping the app away
     * then destroys only the Activity — the engine (and with it the Dart
     * isolate, the WebRTC session and the signaling sockets) keeps running
     * inside the process, which the foreground service keeps alive. Opening
     * the app again simply re-attaches to the still-live session.
     */
    override fun getCachedEngineId(): String = ENGINE_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        // Must happen before super.onCreate(): the activity delegate looks
        // the engine up in the cache during super.onCreate().
        prewarmEngine()
        super.onCreate(savedInstanceState)
    }

    private fun prewarmEngine() {
        if (FlutterEngineCache.getInstance().get(ENGINE_ID) != null) {
            return
        }
        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "intercom.native").setMethodCallHandler {
                call,
                result,
            ->
            handleMethodCall(call.method, call.arguments, result)
        }

        EventChannel(messenger, "intercom.native/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    NativeEvents.setSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    NativeEvents.setSink(null)
                }
            },
        )
    }

    private fun handleMethodCall(
        method: String,
        arguments: Any?,
        result: MethodChannel.Result,
    ) {
        when (method) {
            "startService" -> {
                val map = arguments as? Map<*, *>
                val title = (map?.get("title") as? String) ?: "Talkie"
                val text = (map?.get("text") as? String) ?: "Session active"
                val intent = Intent(this, IntercomService::class.java).apply {
                    action = IntercomService.ACTION_START
                    putExtra(IntercomService.EXTRA_TITLE, title)
                    putExtra(IntercomService.EXTRA_TEXT, text)
                }
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                } catch (error: Exception) {
                    result.error("startService", error.message, null)
                }
            }
            "updateService" -> {
                val map = arguments as? Map<*, *>
                val text = (map?.get("text") as? String) ?: ""
                val intent = Intent(this, IntercomService::class.java).apply {
                    action = IntercomService.ACTION_UPDATE
                    putExtra(IntercomService.EXTRA_TEXT, text)
                }
                try {
                    startService(intent)
                    result.success(null)
                } catch (error: Exception) {
                    result.error("updateService", error.message, null)
                }
            }
            "stopService" -> {
                val intent = Intent(this, IntercomService::class.java).apply {
                    action = IntercomService.ACTION_STOP
                }
                try {
                    startService(intent)
                } catch (_: Exception) {
                    // Service not running; ignore.
                }
                result.success(null)
            }
            "recoverAudio" -> {
                IntercomService.recoverAudio(applicationContext)
                result.success(null)
            }
            "getAudioRoutes" -> result.success(getAudioRoutes())
            "setAudioRoute" -> {
                val id = (arguments as? Map<*, *>)?.get("id") as? String ?: ""
                result.success(setAudioRoute(id))
            }
            "setKeepScreenOn" -> {
                val enabled =
                    (arguments as? Map<*, *>)?.get("enabled") as? Boolean ?: false
                runOnUiThread {
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                result.success(null)
            }
            "openHotspotSettings" -> {
                openHotspotSettings()
                result.success(null)
            }
            "requestIgnoreBatteryOptimizations" -> {
                result.success(requestBatteryExemption())
            }
            "pickMusicFile" -> {
                pendingMusicPick = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "audio/*"
                }
                try {
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, PICK_MUSIC_REQUEST)
                } catch (error: Exception) {
                    pendingMusicPick = null
                    result.error("pickMusic", error.message, null)
                }
            }
            "musicLoad" -> {
                val path = (arguments as? Map<*, *>)?.get("path") as? String ?: ""
                result.success(musicLoad(path))
            }
            "musicPlay" -> {
                try {
                    musicPlayer?.start()
                } catch (_: Exception) {
                }
                result.success(null)
            }
            "musicPause" -> {
                try {
                    musicPlayer?.pause()
                } catch (_: Exception) {
                }
                result.success(null)
            }
            "musicStop" -> {
                stopMusicPlayer()
                result.success(null)
            }
            "musicSeek" -> {
                val ms = (arguments as? Map<*, *>)?.get("ms") as? Int ?: 0
                try {
                    musicPlayer?.seekTo(ms)
                } catch (_: Exception) {
                }
                result.success(null)
            }
            "musicPosition" -> {
                val position = try {
                    musicPlayer?.currentPosition ?: 0
                } catch (_: Exception) {
                    0
                }
                result.success(position)
            }
            "platformInfo" -> {
                result.success(
                    mapOf(
                        "platform" to "android",
                        "osVersion" to "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                        "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
                    ),
                )
            }
            else -> result.notImplemented()
        }
    }

    // -----------------------------------------------------------------
    // Shared music
    // -----------------------------------------------------------------

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_MUSIC_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingMusicPick
        pendingMusicPick = null
        val uri = data?.data
        if (result == null) {
            return
        }
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        // Copy off the SAF provider on a worker thread; the channel result
        // must then be delivered back on the main thread.
        Thread {
            try {
                val name = queryDisplayName(uri) ?: "shared-audio"
                val safe = name.replace(Regex("[^A-Za-z0-9._ -]"), "_")
                val outFile = File(
                    cacheDir,
                    "picked_${System.currentTimeMillis()}_$safe",
                )
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(outFile).use { output -> input.copyTo(output) }
                } ?: throw IllegalStateException("cannot open $uri")
                runOnUiThread {
                    result.success(
                        mapOf("path" to outFile.absolutePath, "name" to name),
                    )
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("pickMusic", error.message, null)
                }
            }
        }.start()
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    /** Prepares a local audio file; returns its duration in ms (0 = failure). */
    private fun musicLoad(path: String): Int {
        stopMusicPlayer()
        if (path.isEmpty()) {
            return 0
        }
        return try {
            val player = MediaPlayer()
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            player.setDataSource(path)
            player.prepare()
            musicPlayer = player
            player.duration
        } catch (error: Exception) {
            android.util.Log.w("Talkie", "musicLoad failed: $error")
            stopMusicPlayer()
            0
        }
    }

    private fun stopMusicPlayer() {
        try {
            musicPlayer?.let {
                if (it.isPlaying) it.stop()
            }
        } catch (_: Exception) {
        }
        try {
            musicPlayer?.release()
        } catch (_: Exception) {
        }
        musicPlayer = null
    }

    // -----------------------------------------------------------------
    // Audio routes
    // -----------------------------------------------------------------

    private fun audioManager(): AudioManager =
        getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun routeTypeFor(device: AudioDeviceInfo): String? = when (device.type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        // LE Audio headsets: API 31+ constant, inlined at compile time so
        // referencing it is safe on older runtimes too.
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        -> "bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        -> "wired"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        else -> null
    }

    private fun deviceName(device: AudioDeviceInfo): String {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                !device.productName.isNullOrBlank()
            ) {
                device.productName.toString()
            } else {
                defaultNameForType(routeTypeFor(device))
            }
        } catch (_: Exception) {
            defaultNameForType(routeTypeFor(device))
        }
    }

    private fun defaultNameForType(type: String?): String = when (type) {
        "bluetooth" -> "Bluetooth headset"
        "wired" -> "Wired headset"
        "speaker" -> "Speakerphone"
        "earpiece" -> "Earpiece"
        else -> "Audio device"
    }

    private fun getAudioRoutes(): List<Map<String, Any>> {
        val am = audioManager()
        val routes = ArrayList<Map<String, Any>>()
        val seenTypes = HashSet<String>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val currentId = try {
                am.communicationDevice?.id
            } catch (_: Exception) {
                null
            }
            for (device in am.availableCommunicationDevices) {
                val type = routeTypeFor(device) ?: continue
                routes.add(
                    mapOf(
                        "id" to "comm:${device.id}",
                        "name" to deviceName(device),
                        "type" to type,
                        "selected" to (currentId == device.id),
                    ),
                )
                seenTypes.add(type)
            }
        } else {
            val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val isSpeaker = am.isSpeakerphoneOn
            val isSco = try {
                am.isBluetoothScoOn
            } catch (_: Exception) {
                false
            }
            for (device in outputs) {
                val type = routeTypeFor(device) ?: continue
                if (seenTypes.contains(type)) {
                    continue
                }
                seenTypes.add(type)
                val selected = when (type) {
                    "bluetooth" -> isSco
                    "speaker" -> isSpeaker && !isSco
                    "earpiece" -> !isSpeaker && !isSco
                    else -> false
                }
                routes.add(
                    mapOf(
                        "id" to "legacy:$type",
                        "name" to defaultNameForType(type),
                        "type" to type,
                        "selected" to selected,
                    ),
                )
            }
        }
        return routes
    }

    private fun setAudioRoute(id: String): Boolean {
        val am = audioManager()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (id.startsWith("comm:")) {
                val targetId = id.removePrefix("comm:").toIntOrNull() ?: return false
                val device = am.availableCommunicationDevices.firstOrNull {
                    it.id == targetId
                } ?: return false
                return try {
                    am.setCommunicationDevice(device)
                } catch (_: Exception) {
                    false
                }
            }
            return false
        }

        // Legacy path (< Android 12).
        val type = id.removePrefix("legacy:")
        return try {
            when (type) {
                "bluetooth" -> {
                    am.startBluetoothSco()
                    am.isBluetoothScoOn = true
                    true
                }
                "speaker" -> {
                    am.stopBluetoothSco()
                    am.isBluetoothScoOn = false
                    am.isSpeakerphoneOn = true
                    true
                }
                "earpiece" -> {
                    am.stopBluetoothSco()
                    am.isBluetoothScoOn = false
                    am.isSpeakerphoneOn = false
                    true
                }
                else -> false
            }
        } catch (_: Exception) {
            false
        }
    }

    // -----------------------------------------------------------------
    // System settings helpers
    // -----------------------------------------------------------------

    private fun openHotspotSettings() {
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Intent(Settings.Panel.ACTION_INTERNET_CONNECTIVITY)
            } else {
                Intent(Settings.ACTION_WIRELESS_SETTINGS)
            }
            startActivity(intent)
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))
            } catch (_: Exception) {
                // Give up quietly.
            }
        }
    }

    private fun requestBatteryExemption(): Boolean {
        return try {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName"),
            )
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
