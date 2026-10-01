package com.example.intercom_talkie

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Single place where native components (foreground service, activity) push
 * events to the Dart side over `intercom.native/events`.
 */
object NativeEvents {
    @Volatile
    var sink: EventChannel.EventSink? = null
        private set

    private val mainHandler = Handler(Looper.getMainLooper())

    fun setSink(newSink: EventChannel.EventSink?) {
        mainHandler.post { sink = newSink }
    }

    /**
     * Posts an event; must be called from any thread.
     * [type] is one of: interruptionBegan, interruptionEnded, focusLoss,
     * focusGain, routeChanged, serviceStopped, mediaServicesReset,
     * missingPermissions.
     */
    fun post(type: String, data: String? = null) {
        mainHandler.post {
            val currentSink = sink ?: return@post
            val payload = HashMap<String, Any?>()
            payload["type"] = type
            if (data != null) {
                payload["data"] = data
            }
            try {
                currentSink.success(payload)
            } catch (_: Exception) {
                // Sink went away; ignore.
            }
        }
    }
}
