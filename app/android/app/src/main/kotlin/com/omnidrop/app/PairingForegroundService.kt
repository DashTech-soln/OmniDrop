package com.omnidrop.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.pm.ServiceInfo
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.SocketException
import java.util.ArrayDeque
import java.util.Collections
import java.util.IdentityHashMap
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

internal object PairingNativeLog {
    private const val PREFERENCES = "native_pairing"
    private const val LOG_KEY = "steps"
    private const val ACTIVE_KEY = "service_active"
    private const val PID_KEY = "service_pid"
    private const val MAX_ENTRIES = 50
    private const val PROCESS_MARKER = "pairing_process_active"

    @Synchronized
    fun append(context: Context, step: String, message: String) {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val entries = JSONArray(preferences.getString(LOG_KEY, "[]"))
        entries.put(
            JSONObject()
                .put("timestamp", System.currentTimeMillis())
                .put("step", step)
                .put("message", message),
        )
        while (entries.length() > MAX_ENTRIES) entries.remove(0)
        preferences.edit().putString(LOG_KEY, entries.toString()).apply()
    }

    fun markServiceActive(context: Context) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putBoolean(ACTIVE_KEY, true)
            .putInt(PID_KEY, Process.myPid())
            .apply()
    }

    fun markServiceStopped(context: Context) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putBoolean(ACTIVE_KEY, false).apply()
    }

    fun recoverProcessTermination(context: Context) {
        val marker = java.io.File(context.filesDir, PROCESS_MARKER)
        if (marker.exists()) {
            val previousPid = marker.readText().toIntOrNull()
            if (previousPid != Process.myPid()) {
                val recent = read(context).takeLast(20).joinToString("\n") { entry ->
                    "${entry["step"]}: ${entry["message"]}"
                }
                append(context, "previous_run_unexpectedly", "previous run ended unexpectedly\n$recent")
            }
        }
        marker.writeText(Process.myPid().toString())
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (preferences.getBoolean(ACTIVE_KEY, false) && preferences.getInt(PID_KEY, -1) != Process.myPid()) {
            append(context, "teardown_reason", "process_destroyed")
            markServiceStopped(context)
        }
    }

    fun clearProcessMarker(context: Context) {
        java.io.File(context.filesDir, PROCESS_MARKER).delete()
    }

    fun read(context: Context): List<Map<String, Any>> {
        val entries = JSONArray(context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(LOG_KEY, "[]"))
        return (0 until entries.length()).mapNotNull { index ->
            entries.optJSONObject(index)?.let { entry ->
                mapOf(
                    "timestamp" to entry.optLong("timestamp"),
                    "step" to entry.optString("step"),
                    "message" to entry.optString("message"),
                )
            }
        }
    }
}

class PairingForegroundService : Service() {
    private enum class HotspotState { STOPPED, STARTING, ACTIVE, STOPPING }

    private data class QueuedOperation(val action: String, val reason: String, val generation: Long)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val operationQueue = ArrayDeque<QueuedOperation>()
    private val closedReservations = Collections.newSetFromMap(IdentityHashMap<WifiManager.LocalOnlyHotspotReservation, Boolean>())
    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var hotspotCallback: WifiManager.LocalOnlyHotspotCallback? = null
    private var hotspotState = HotspotState.STOPPED
    private var generation = 0L
    private var operationInFlight = false
    private var retryCount = 0
    private var stopReason = "user_disconnect"
    private var stopTimeout: Runnable? = null
    private var hotspotStartResultSent = false
    private var serviceDestroyed = false
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var notificationDisconnect = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        try {
            ensureNotificationChannel()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    createNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, createNotification())
            }
            PairingNativeLog.append(this, "service_started", "Foreground service entered foreground in onCreate")
        } catch (error: Throwable) {
            PairingNativeLog.append(this, "service_started", "Foreground startup failed: ${error.javaClass.simpleName}: ${error.message}")
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_START || action == ACTION_STOP || action == ACTION_KEEP_ALIVE) {
            mainHandler.post {
                when (action) {
                    ACTION_START -> enqueueStart()
                    ACTION_KEEP_ALIVE -> enqueue(QueuedOperation(action, "connection_active", generation))
                    ACTION_STOP -> enqueueStop(intent.getStringExtra(EXTRA_STOP_REASON) ?: "user_disconnect")
                }
            }
        } else {
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun enqueueStart() {
        if (hotspotState == HotspotState.ACTIVE || hotspotState == HotspotState.STARTING) return
        generation += 1
        enqueue(QueuedOperation(ACTION_START, "pairing_start", generation))
    }

    private fun enqueueStop(reason: String) {
        generation += 1
        stopReason = reason
        notificationDisconnect = reason == "notification_disconnect"
        if (hotspotState == HotspotState.STARTING && operationInFlight) {
            hotspotState = HotspotState.STOPPING
            awaitHotspotStopped()
        }
        enqueue(QueuedOperation(ACTION_STOP, reason, generation))
    }

    private fun enqueue(operation: QueuedOperation) {
        operationQueue.addLast(operation)
        pumpQueue()
    }

    private fun pumpQueue() {
        if (operationInFlight || operationQueue.isEmpty()) return
        val operation = operationQueue.removeFirst()
        when (operation.action) {
            ACTION_START -> {
                if (operation.generation != generation) {
                    pumpQueue()
                    return
                }
                if (hotspotState == HotspotState.ACTIVE) {
                    pumpQueue()
                    return
                }
                operationInFlight = true
                retryCount = 0
                hotspotStartResultSent = false
                hotspotState = HotspotState.STARTING
                startHotspot(operation.generation)
            }
            ACTION_KEEP_ALIVE -> {
                startKeepAlive()
                pumpQueue()
            }
            ACTION_STOP -> {
                operationInFlight = true
                stopHotspot(operation.reason)
            }
        }
    }

    private fun startHotspot(operationGeneration: Long) {
        try {
            PairingNativeLog.markServiceActive(this)
            PairingNativeLog.append(this, "service_started", "Pairing foreground service started")

            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiManager == null) {
                failToStart(operationGeneration, "HOTSPOT_UNAVAILABLE", "Wi-Fi is unavailable on this device.")
                return
            }
            val callback = object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        if (serviceDestroyed) {
                            PairingNativeLog.append(this@PairingForegroundService, "hotspot_on_started", "Ignored reservation callback after service destruction")
                            closeReservationOnce(reservation)
                            return
                        }
                        runCallbackSafely("hotspot_on_started") {
                            if (operationGeneration != generation || hotspotState != HotspotState.STARTING) {
                                closeReservationOnce(reservation)
                                if (hotspotState == HotspotState.STOPPING) finishStop()
                                else completeOperation()
                                return@runCallbackSafely
                            }
                            hotspotReservation = reservation
                            hotspotState = HotspotState.ACTIVE
                            readHotspotCredentials(reservation, wifiManager, operationGeneration)
                        }
                    }

                    override fun onStopped() {
                        runCallbackSafely("hotspot_on_stopped") {
                            if (hotspotCallback !== this) return@runCallbackSafely
                            hotspotReservation = null
                            if (hotspotState == HotspotState.STOPPING) {
                                finishStop()
                            } else {
                                hotspotState = HotspotState.STOPPED
                                PairingNativeLog.append(this@PairingForegroundService, "teardown_reason", "hotspot_stopped")
                                sendDisconnectBroadcast("hotspot_stopped")
                                releaseLocks()
                                PairingNativeLog.markServiceStopped(this@PairingForegroundService)
                                stopSelf()
                            }
                        }
                    }

                    override fun onFailed(reason: Int) {
                        runCallbackSafely("hotspot_on_failed") {
                            if (operationGeneration != generation || hotspotState != HotspotState.STARTING) {
                                completeOperation()
                                return@runCallbackSafely
                            }
                            val code = when (reason) {
                                ERROR_INCOMPATIBLE_MODE -> "HOTSPOT_INCOMPATIBLE_MODE"
                                ERROR_NO_CHANNEL -> "HOTSPOT_NO_CHANNEL"
                                ERROR_TETHERING_DISALLOWED -> "HOTSPOT_TETHERING_DISALLOWED"
                                else -> "HOTSPOT_START_FAILED"
                            }
                            val message = when (reason) {
                                ERROR_NO_CHANNEL -> "No Wi-Fi channel is available to start the hotspot."
                                ERROR_INCOMPATIBLE_MODE -> "Wi-Fi is in a mode that cannot start a local-only hotspot."
                                ERROR_TETHERING_DISALLOWED -> "The system does not allow hotspot tethering."
                                else -> "Android could not start the local-only hotspot."
                            }
                            if (code == "HOTSPOT_START_FAILED" && retryCount == 0) {
                                retryCount += 1
                                PairingNativeLog.append(this@PairingForegroundService, "hotspot_start_result", "retrying_after_delay")
                                mainHandler.postDelayed({
                                    if (!serviceDestroyed && operationGeneration == generation && hotspotState == HotspotState.STARTING) {
                                        startHotspot(operationGeneration)
                                    } else {
                                        completeOperation()
                                    }
                                }, HOTSPOT_RETRY_DELAY_MS)
                            } else {
                                failToStart(operationGeneration, code, message)
                            }
                        }
                    }
                }
            hotspotCallback = callback
            wifiManager.startLocalOnlyHotspot(
                callback,
                mainHandler,
            )
        } catch (error: Throwable) {
            if (error is RuntimeException && retryCount == 0 && operationGeneration == generation) {
                retryCount += 1
                mainHandler.postDelayed({
                    if (!serviceDestroyed && operationGeneration == generation && hotspotState == HotspotState.STARTING) {
                        startHotspot(operationGeneration)
                    } else {
                        completeOperation()
                    }
                }, HOTSPOT_RETRY_DELAY_MS)
            } else {
                val code = if (error is SecurityException) "HOTSPOT_PERMISSION_DENIED" else "HOTSPOT_START_FAILED"
                val message = if (error is SecurityException) {
                    "Android denied permission to start the hotspot."
                } else {
                    "Android could not start the local-only hotspot."
                }
                failToStart(operationGeneration, code, message, error)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun readHotspotCredentials(
        reservation: WifiManager.LocalOnlyHotspotReservation,
        wifiManager: WifiManager,
        operationGeneration: Long,
    ) {
        try {
            val credentials = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val config = reservation.softApConfiguration
                config.ssid to config.passphrase
            } else {
                val config = reservation.wifiConfiguration
                config?.SSID to config?.preSharedKey
            }
            if (credentials.first.isNullOrEmpty() || credentials.second.isNullOrEmpty()) {
                failToStart(operationGeneration, "HOTSPOT_CREDENTIALS_UNAVAILABLE", "Android did not provide hotspot credentials.")
                return
            }
            PairingNativeLog.append(this, "credentials_obtained", "Hotspot credentials obtained")
            val hostIp = findHotspotHostIp()
            if (hostIp == null) {
                failToStart(operationGeneration, "HOTSPOT_ADDRESS_UNAVAILABLE", "Android did not expose a reachable hotspot address.")
                return
            }
            PairingNativeLog.append(this, "hotspot_start_result", "success")
            sendHotspotResult(
                mapOf(
                    "success" to true,
                    "ssid" to credentials.first!!,
                    "password" to credentials.second!!,
                    "supports5GHz" to wifiManager.is5GHzBandSupported,
                    "canRequest5GHz" to false,
                    "hostIp" to hostIp,
                ),
            )
            completeOperation()
        } catch (error: Throwable) {
            failToStart(operationGeneration, "HOTSPOT_START_FAILED", "Android could not read the hotspot details.", error)
        }
    }

    private fun startKeepAlive() {
        try {
            connectionActive = true
            PairingNativeLog.markServiceActive(this)
            PairingNativeLog.append(this, "service_started", "Pairing connection foreground service started")
            acquireLocks()
            val connectivityManager = getSystemService(ConnectivityManager::class.java)
            val boundNetwork = connectivityManager?.boundNetworkForProcess
            if (boundNetwork != null) connectivityManager.bindProcessToNetwork(boundNetwork)
        } catch (error: Throwable) {
            PairingNativeLog.append(this, "service_started", "Keep-alive setup failed: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun failToStart(operationGeneration: Long, code: String, message: String, error: Throwable? = null) {
        if (operationGeneration != generation || hotspotState == HotspotState.STOPPING) {
            completeOperation()
            return
        }
        if (error != null) PairingNativeLog.append(this, "hotspot_start_failure", "${error.javaClass.simpleName}: ${error.message}")
        PairingNativeLog.append(this, "hotspot_start_result", code)
        sendHotspotResult(mapOf("success" to false, "code" to code, "message" to message))
        hotspotState = if (hotspotReservation == null) HotspotState.STOPPED else HotspotState.STOPPING
        if (hotspotReservation != null) {
            stopReason = "startup_failed"
            closeReservationOnce(hotspotReservation!!)
            awaitHotspotStopped()
        } else {
            PairingNativeLog.markServiceStopped(this)
            stopForegroundService()
            completeOperation()
        }
    }

    private fun stopHotspot(reason: String) {
        stopReason = reason
        if (!hotspotStartResultSent) {
            PairingNativeLog.append(this, "hotspot_start_result", "HOTSPOT_CANCELLED")
            sendHotspotResult(
                mapOf(
                    "success" to false,
                    "code" to "HOTSPOT_CANCELLED",
                    "message" to "Pairing hotspot startup was cancelled.",
                ),
            )
        }
        val wasStarting = hotspotState == HotspotState.STARTING
        hotspotState = HotspotState.STOPPING
        if (hotspotReservation != null) closeReservationOnce(hotspotReservation!!)
        if (wasStarting || hotspotReservation != null) {
            awaitHotspotStopped()
        } else {
            finishStop()
        }
    }

    private fun awaitHotspotStopped() {
        stopTimeout?.let(mainHandler::removeCallbacks)
        stopTimeout = Runnable {
            if (hotspotState == HotspotState.STOPPING) {
                PairingNativeLog.append(this, "hotspot_stop_timeout", "Hotspot stop callback did not arrive within five seconds")
                finishStop()
            }
        }.also { mainHandler.postDelayed(it, HOTSPOT_STOP_TIMEOUT_MS) }
    }

    private fun finishStop() {
        if (hotspotState != HotspotState.STOPPING) return
        stopTimeout?.let(mainHandler::removeCallbacks)
        stopTimeout = null
        hotspotReservation = null
        hotspotCallback = null
        hotspotState = HotspotState.STOPPED
        PairingNativeLog.append(this, "teardown_reason", stopReason)
        PairingNativeLog.markServiceStopped(this)
        PairingNativeLog.clearProcessMarker(this)
        releaseNetworkRequest()
        unbindProcessNetwork()
        connectionActive = false
        releaseLocks()
        stopForegroundService()
        if (notificationDisconnect) sendDisconnectBroadcast("notification_disconnect")
        notificationDisconnect = false
        completeOperation()
    }

    private fun completeOperation() {
        operationInFlight = false
        pumpQueue()
        if (!operationInFlight && operationQueue.isEmpty() && hotspotState == HotspotState.STOPPED) stopSelf()
    }

    private fun runCallbackSafely(step: String, callback: () -> Unit) {
        if (serviceDestroyed) return
        try {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                callback()
            } else {
                mainHandler.post {
                    try {
                        callback()
                    } catch (error: Throwable) {
                        PairingNativeLog.append(this, step, "${error.javaClass.simpleName}: ${error.message}")
                    }
                }
            }
        } catch (error: Throwable) {
            PairingNativeLog.append(this, step, "${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun closeReservationOnce(reservation: WifiManager.LocalOnlyHotspotReservation) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { closeReservationOnce(reservation) }
            return
        }
        if (!closedReservations.add(reservation)) return
        try {
            reservation.close()
        } catch (error: Throwable) {
            PairingNativeLog.append(this, "hotspot_reservation_close", "${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun stopForegroundService() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (error: Throwable) {
            PairingNativeLog.append(this, "service_stop_foreground", "${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun acquireLocks() {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiLock == null && wifiManager != null) {
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wifiManager.createWifiLock(mode, "OmniDrop:Pairing").apply {
                    setReferenceCounted(false)
                    if (!isHeld) acquire()
                }
            }
            val powerManager = getSystemService(PowerManager::class.java)
            if (wakeLock == null && powerManager != null) {
                wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OmniDrop:Pairing").apply {
                    setReferenceCounted(false)
                    if (!isHeld) acquire()
                }
            }
            PairingNativeLog.append(this, "keepalive_locks", "Wi-Fi and partial wake locks acquired")
        } catch (error: Throwable) {
            PairingNativeLog.append(this, "keepalive_locks", "Lock acquisition failed: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun releaseLocks() {
        listOfNotNull(wifiLock, wakeLock).forEach { lock ->
            try {
                if (lock.isHeld) lock.release()
            } catch (error: Throwable) {
                PairingNativeLog.append(this, "keepalive_locks", "Lock release failed: ${error.javaClass.simpleName}: ${error.message}")
            }
        }
        wifiLock = null
        wakeLock = null
    }

    private fun unbindProcessNetwork() {
        try {
            getSystemService(ConnectivityManager::class.java)?.bindProcessToNetwork(null)
        } catch (error: Throwable) {
            PairingNativeLog.append(this, "bind_result", "Unbind failed: ${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun sendDisconnectBroadcast(reason: String) {
        try {
            sendBroadcast(Intent(ACTION_PAIRING_DISCONNECTED).setPackage(packageName).putExtra(EXTRA_STOP_REASON, reason))
        } catch (error: Throwable) {
            PairingNativeLog.append(this, "disconnect_broadcast", "${error.javaClass.simpleName}: ${error.message}")
        }
    }

    override fun onDestroy() {
        serviceDestroyed = true
        try {
            stopTimeout?.let(mainHandler::removeCallbacks)
            hotspotReservation?.let(::closeReservationOnce)
            hotspotReservation = null
            releaseNetworkRequest()
            unbindProcessNetwork()
            releaseLocks()
            connectionActive = false
            if (hotspotState != HotspotState.STOPPED) {
                PairingNativeLog.append(this, "teardown_reason", "process_destroyed")
                PairingNativeLog.markServiceStopped(this)
            }
        } catch (error: Throwable) {
            PairingNativeLog.append(this, "service_destroyed", "${error.javaClass.simpleName}: ${error.message}")
        } finally {
            super.onDestroy()
        }
    }

    private fun sendHotspotResult(values: Map<String, Any>) {
        if (hotspotStartResultSent) return
        hotspotStartResultSent = true
        try {
            val intent = Intent(ACTION_HOTSPOT_RESULT).setPackage(packageName)
            values.forEach { (key, value) ->
                when (value) {
                    is Boolean -> intent.putExtra(key, value)
                    is String -> intent.putExtra(key, value)
                }
            }
            sendBroadcast(intent)
        } catch (error: Throwable) {
            PairingNativeLog.append(this, "hotspot_result_broadcast", "${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Pairing", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun createNotification(text: String = "Hotspot active"): Notification {
        val disconnectIntent = Intent(this, PairingForegroundService::class.java)
            .setAction(ACTION_STOP)
            .putExtra(EXTRA_STOP_REASON, "notification_disconnect")
        val disconnectPendingIntent = PendingIntent.getService(
            this,
            NOTIFICATION_ID,
            disconnectIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("OmniDrop pairing")
            .setContentText(text)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Disconnect", disconnectPendingIntent)
            .build()
    }

    private fun findHotspotHostIp(): String? {
        val networkInterfaces = try {
            NetworkInterface.getNetworkInterfaces()
        } catch (_: SocketException) {
            return null
        } ?: return null
        val candidates = mutableListOf<String>()
        while (networkInterfaces.hasMoreElements()) {
            val networkInterface = networkInterfaces.nextElement()
            val name = networkInterface.name.lowercase(Locale.ROOT)
            if (!name.startsWith("wlan") && !name.startsWith("ap") && !name.startsWith("swlan")) continue
            val addresses = networkInterface.inetAddresses
            while (addresses.hasMoreElements()) {
                val address = addresses.nextElement()
                if (address is Inet4Address && !address.isLoopbackAddress && address.isSiteLocalAddress) {
                    candidates.add(address.hostAddress ?: continue)
                }
            }
        }
        return candidates.firstOrNull { it.endsWith(".1") } ?: candidates.singleOrNull()
    }

    companion object {
        const val ACTION_START = "com.omnidrop.app.action.START_PAIRING_HOTSPOT"
        const val ACTION_KEEP_ALIVE = "com.omnidrop.app.action.KEEP_PAIRING_ALIVE"
        const val ACTION_STOP = "com.omnidrop.app.action.STOP_PAIRING_HOTSPOT"
        const val ACTION_HOTSPOT_RESULT = "com.omnidrop.app.action.PAIRING_HOTSPOT_RESULT"
        const val ACTION_PAIRING_DISCONNECTED = "com.omnidrop.app.action.PAIRING_DISCONNECTED"
        const val EXTRA_STOP_REASON = "stop_reason"
        private const val CHANNEL_ID = "pairing_hotspot"
        private const val NOTIFICATION_ID = 4107
        private const val HOTSPOT_RETRY_DELAY_MS = 2_000L
        private const val HOTSPOT_STOP_TIMEOUT_MS = 5_000L
        private var retainedContext: Context? = null
        private var retainedConnectivityManager: ConnectivityManager? = null
        private var retainedNetworkCallback: ConnectivityManager.NetworkCallback? = null
        @Volatile
        private var connectionActive = false

        fun isConnectionActive(): Boolean = connectionActive

        @Synchronized
        fun retainNetworkRequest(context: Context, manager: ConnectivityManager, callback: ConnectivityManager.NetworkCallback) {
            retainedContext = context.applicationContext
            retainedConnectivityManager = manager
            retainedNetworkCallback = callback
        }

        @Synchronized
        fun releaseNetworkRequest(): Boolean {
            val manager = retainedConnectivityManager
            val callback = retainedNetworkCallback
            val context = retainedContext
            retainedContext = null
            retainedConnectivityManager = null
            retainedNetworkCallback = null
            if (manager == null || callback == null) return false
            try {
                manager.unregisterNetworkCallback(callback)
            } catch (error: Throwable) {
                PairingNativeLog.append(
                    context ?: return true,
                    "network_callback_release",
                    "${error.javaClass.simpleName}: ${error.message}",
                )
            }
            return true
        }
    }
}
