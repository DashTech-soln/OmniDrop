package com.omnidrop.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.pm.ServiceInfo
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import androidx.core.app.NotificationCompat
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.SocketException
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

internal object PairingNativeLog {
    private const val PREFERENCES = "native_pairing"
    private const val LOG_KEY = "steps"
    private const val ACTIVE_KEY = "service_active"
    private const val PID_KEY = "service_pid"
    private const val MAX_ENTRIES = 50

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
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (preferences.getBoolean(ACTIVE_KEY, false) && preferences.getInt(PID_KEY, -1) != Process.myPid()) {
            append(context, "teardown_reason", "process_destroyed")
            markServiceStopped(context)
        }
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
    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var explicitlyStopped = false
    private var hotspotStartResultSent = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startHotspot()
            ACTION_KEEP_ALIVE -> startKeepAlive()
            ACTION_STOP -> stopPairing(intent?.getStringExtra(EXTRA_STOP_REASON) ?: "user_disconnect")
            else -> stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun startHotspot() {
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
            PairingNativeLog.markServiceActive(this)
            PairingNativeLog.append(this, "service_started", "Pairing foreground service started")

            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiManager == null) {
                failToStart("HOTSPOT_UNAVAILABLE", "Wi-Fi is unavailable on this device.")
                return
            }
            wifiManager.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        if (explicitlyStopped) {
                            reservation.close()
                            return
                        }
                        hotspotReservation = reservation
                        val credentials = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            val config = reservation.softApConfiguration
                            config.ssid to config.passphrase
                        } else {
                            @Suppress("DEPRECATION")
                            val config = reservation.wifiConfiguration
                            config?.SSID to config?.preSharedKey
                        }
                        if (credentials.first.isNullOrEmpty() || credentials.second.isNullOrEmpty()) {
                            failToStart("HOTSPOT_CREDENTIALS_UNAVAILABLE", "Android did not provide hotspot credentials.")
                            return
                        }
                        PairingNativeLog.append(this@PairingForegroundService, "credentials_obtained", "Hotspot credentials obtained")
                        val hostIp = findHotspotHostIp()
                        if (hostIp == null) {
                            failToStart("HOTSPOT_ADDRESS_UNAVAILABLE", "Android did not expose a reachable hotspot address.")
                            return
                        }
                        val supports5GHz = wifiManager.is5GHzBandSupported
                        PairingNativeLog.append(this@PairingForegroundService, "hotspot_start_result", "success")
                        sendHotspotResult(
                            mapOf(
                                "success" to true,
                                "ssid" to credentials.first!!,
                                "password" to credentials.second!!,
                                "supports5GHz" to supports5GHz,
                                "canRequest5GHz" to false,
                                "hostIp" to hostIp,
                            ),
                        )
                    }

                    override fun onStopped() {
                        hotspotReservation = null
                        if (!explicitlyStopped) {
                            PairingNativeLog.append(this@PairingForegroundService, "teardown_reason", "hotspot_stopped")
                            sendBroadcast(Intent(ACTION_PAIRING_DISCONNECTED).setPackage(packageName))
                            stopSelf()
                        }
                    }

                    override fun onFailed(reason: Int) {
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
                        failToStart(code, message)
                    }
                },
                Handler(Looper.getMainLooper()),
            )
        } catch (error: SecurityException) {
            failToStart("HOTSPOT_PERMISSION_DENIED", error.message ?: "Android denied permission to start the hotspot.")
        } catch (error: RuntimeException) {
            failToStart("HOTSPOT_START_FAILED", error.message ?: "Android could not start the local-only hotspot.")
        }
    }

    private fun startKeepAlive() {
        try {
            ensureNotificationChannel()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    createNotification("Pairing connection active"),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, createNotification("Pairing connection active"))
            }
            hotspotStartResultSent = true
            PairingNativeLog.markServiceActive(this)
            PairingNativeLog.append(this, "service_started", "Pairing connection foreground service started")
        } catch (error: SecurityException) {
            PairingNativeLog.append(this, "service_started", "failed")
            stopSelf()
        } catch (error: RuntimeException) {
            PairingNativeLog.append(this, "service_started", "failed")
            stopSelf()
        }
    }

    private fun failToStart(code: String, message: String) {
        if (explicitlyStopped) return
        PairingNativeLog.append(this, "hotspot_start_result", code)
        sendHotspotResult(mapOf("success" to false, "code" to code, "message" to message))
        stopPairing("startup_failed")
    }

    private fun stopPairing(reason: String) {
        if (explicitlyStopped) return
        explicitlyStopped = true
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
        hotspotReservation?.close()
        hotspotReservation = null
        PairingNativeLog.append(this, "teardown_reason", reason)
        PairingNativeLog.markServiceStopped(this)
        if (reason == "notification_disconnect") {
            sendBroadcast(Intent(ACTION_PAIRING_DISCONNECTED).setPackage(packageName))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        hotspotReservation?.close()
        hotspotReservation = null
        if (!explicitlyStopped) {
            PairingNativeLog.append(this, "teardown_reason", "process_destroyed")
            PairingNativeLog.markServiceStopped(this)
        }
        super.onDestroy()
    }

    private fun sendHotspotResult(values: Map<String, Any>) {
        hotspotStartResultSent = true
        val intent = Intent(ACTION_HOTSPOT_RESULT).setPackage(packageName)
        values.forEach { (key, value) ->
            when (value) {
                is Boolean -> intent.putExtra(key, value)
                is String -> intent.putExtra(key, value)
            }
        }
        sendBroadcast(intent)
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
    }
}
