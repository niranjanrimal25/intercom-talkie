package com.example.intercom_talkie

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

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
                val title = (map?.get("title") as? String) ?: "Intercom Talkie"
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
    // Audio routes
    // -----------------------------------------------------------------

    private fun audioManager(): AudioManager =
        getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun routeTypeFor(device: AudioDeviceInfo): String? = when (device.type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_HEADSET,
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
