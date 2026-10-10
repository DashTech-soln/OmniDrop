package com.omnidrop.app

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.util.Size
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executors
import kotlin.system.exitProcess


private const val CHANNEL = "com.omnidrop.app/localsend"
private const val REQUEST_CODE_PICK_DIRECTORY = 1
private const val REQUEST_CODE_PICK_DIRECTORY_PATH = 2
private const val REQUEST_CODE_PICK_FILE = 3
private const val REQUEST_CODE_LOCAL_NETWORK = 4
private const val REQUEST_CODE_PICK_FOLDER_TREE = 5
private const val REQUEST_CODE_PICK_STORAGE_TREE = 6
private const val REQUEST_CODE_LOCAL_ONLY_HOTSPOT = 7
private const val REQUEST_CODE_WIFI_HOTSPOT = 8
private const val REQUEST_CODE_PAIRING_NOTIFICATIONS = 9
private const val WIFI_CONNECT_TIMEOUT_MS = 30_000L

// Not available as a constant in compileSdk 36.
private const val PERMISSION_ACCESS_LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
private const val PERMISSION_NEARBY_WIFI_DEVICES = "android.permission.NEARBY_WIFI_DEVICES"
private const val PERMISSION_POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS"
private const val API_LEVEL_ANDROID_17 = 37
private const val NATIVE_CRASH_FILE = "last_native_crash.txt"

private object PairingNativeCrashReport {
    @Volatile
    private var installed = false

    @Synchronized
    fun install(context: Context) {
        if (installed) return
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                File(context.filesDir, NATIVE_CRASH_FILE).writeText(
                    "Time: ${System.currentTimeMillis()}\nThread: ${thread.name}\n${error.stackTraceToString()}",
                )
            } catch (writeError: Exception) {
                android.util.Log.e("OmniDrop", "Could not write native crash report", writeError)
            }
            if (previous != null) {
                previous.uncaughtException(thread, error)
            } else {
                android.os.Process.killProcess(android.os.Process.myPid())
                exitProcess(10)
            }
        }
        installed = true
    }

    fun read(context: Context): String? {
        val file = File(context.filesDir, NATIVE_CRASH_FILE)
        return if (file.exists()) file.readText() else null
    }
}

class MainActivity : FlutterActivity() {
    private val mediaQueryExecutor = Executors.newFixedThreadPool(2)
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingHotspotResult: MethodChannel.Result? = null
    private var pendingStorageLocation = "internal"
    private var pendingStoragePickerForSetting = false
    private var pendingWifiHotspotResult: MethodChannel.Result? = null
    private var pendingWifiHotspotSsid: String? = null
    private var pendingWifiHotspotPassword: String? = null
    private var wifiHotspotNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var wifiHotspotTimeout: Runnable? = null
    private var legacyWifiNetworkId: Int? = null
    private var hotspotReceiverRegistered = false
    private var pairingChannel: MethodChannel? = null
    private val hotspotResultReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == PairingForegroundService.ACTION_PAIRING_DISCONNECTED) {
                pairingChannel?.invokeMethod("pairingDisconnected", null)
                return
            }
            val result = pendingHotspotResult ?: return
            pendingHotspotResult = null
            if (intent.getBooleanExtra("success", false)) {
                result.success(
                    mapOf(
                        "ssid" to intent.getStringExtra("ssid"),
                        "password" to intent.getStringExtra("password"),
                        "supports5GHz" to intent.getBooleanExtra("supports5GHz", false),
                        "canRequest5GHz" to intent.getBooleanExtra("canRequest5GHz", false),
                        "hostIp" to intent.getStringExtra("hostIp"),
                    ),
                )
            } else {
                result.error(
                    intent.getStringExtra("code") ?: "HOTSPOT_START_FAILED",
                    intent.getStringExtra("message") ?: "Android could not start the local-only hotspot.",
                    null,
                )
            }
        }
    }

    override fun onDestroy() {
        PairingNativeLog.append(
            applicationContext,
            "activity_destroyed",
            "isFinishing=$isFinishing; isChangingConfigurations=$isChangingConfigurations",
        )
        if (hotspotReceiverRegistered) {
            unregisterReceiver(hotspotResultReceiver)
            hotspotReceiverRegistered = false
        }
        pairingChannel = null
        mediaQueryExecutor.shutdown()
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PairingNativeCrashReport.install(applicationContext)
        PairingNativeLog.recoverProcessTermination(this)
    }

    /// share_handler drops share intents arriving via onNewIntent while the Dart side
    /// is not subscribed to its media stream yet, which happens when this singleTask
    /// activity is relaunched into an existing task while the app is still starting.
    /// Hold such intents back until Dart reports readiness ("shareIntentReady"), then
    /// replay them through the regular plugin path.
    private val pendingShareIntents = mutableListOf<Intent>()
    private var shareIntentReady = false

    override fun onNewIntent(intent: Intent) {
        if (!shareIntentReady && (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE)) {
            pendingShareIntents.add(intent)
            return
        }
        super.onNewIntent(intent)
    }

    private fun onShareIntentReady() {
        shareIntentReady = true
        val pending = pendingShareIntents.toList()
        pendingShareIntents.clear()
        for (intent in pending) {
            super.onNewIntent(intent)
        }
    }

    // Overriding the static methods we need from the Java class, as described
    // in the documentation of `FlutterActivity.NewEngineIntentBuilder`
    companion object {
        fun withNewEngine(): NewEngineIntentBuilder {
            return NewEngineIntentBuilder(MainActivity::class.java)
        }

        fun createDefaultIntent(launchContext: Context): Intent {
            return withNewEngine().build(launchContext)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val hotspotFilter = IntentFilter().apply {
            addAction(PairingForegroundService.ACTION_HOTSPOT_RESULT)
            addAction(PairingForegroundService.ACTION_PAIRING_DISCONNECTED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(hotspotResultReceiver, hotspotFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(hotspotResultReceiver, hotspotFilter)
        }
        hotspotReceiverRegistered = true
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        pairingChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDirectory" -> {
                    pendingResult = result
                    openDirectoryPicker(onlyPath = false)
                }

                "pickFiles" -> {
                    pendingResult = result
                    openFilePicker()
                }

                "pickDirectoryPath" -> {
                    pendingResult = result
                    openDirectoryPicker(onlyPath = true)
                }

                "pickFolderTree" -> {
                    pendingResult = result
                    pendingStorageLocation = "internal"
                    pendingStoragePickerForSetting = false
                    openStorageTreePicker("internal")
                }

                "pickStorageTree" -> {
                    pendingResult = result
                    val storage = call.argument<String>("storage") ?: "internal"
                    pendingStoragePickerForSetting = false
                    openStorageTreePicker(storage)
                }

                "getStorageTree" -> {
                    val storage = call.argument<String>("storage") ?: "internal"
                    result.success(getStorageTree(storage)?.toString())
                }

                "hasRemovableStorage" -> result.success(hasRemovableStorage())

                "getSaveLocation" -> {
                    val preferences = getSharedPreferences("storage", MODE_PRIVATE)
                    val location = preferences.getString("save_location", "internal") ?: "internal"
                    if (location == "sd" && !hasRemovableStorage()) {
                        preferences.edit().putString("save_location", "internal").apply()
                        result.success("internal")
                    } else {
                        result.success(location)
                    }
                }

                "setSaveLocation" -> {
                    val storage = call.argument<String>("storage") ?: "internal"
                    if (storage == "sd" && !hasRemovableStorage()) {
                        result.success(false)
                    } else {
                        val tree = getStorageTree(storage)
                        if (tree != null) {
                            getSharedPreferences("storage", MODE_PRIVATE).edit().putString("save_location", storage).apply()
                            result.success(true)
                        } else {
                            pendingResult = result
                            pendingStoragePickerForSetting = true
                            openStorageTreePicker(storage)
                        }
                    }
                }

                "listFolderTree" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) result.error("INVALID_ARGUMENT", "Missing folder URI", null)
                    else {
                        try {
                            result.success(listTreeEntries(Uri.parse(uri)))
                        } catch (e: Exception) {
                            result.error("LIST_FOLDER_FAILED", e.message ?: "Could not read this folder", null)
                        }
                    }
                }

                "listFolderTreeFiles" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) result.error("INVALID_ARGUMENT", "Missing folder URI", null)
                    else {
                        try {
                            result.success(listTreeFiles(Uri.parse(uri), ""))
                        } catch (e: Exception) {
                            result.error("LIST_FOLDER_FAILED", e.message ?: "Could not read this folder", null)
                        }
                    }
                }

                "createDirectory" -> handleCreateDirectory(call, result)

                "getFileDescriptor" -> handleGetFileDescriptor(call, result)

                "createFile" -> handleCreateFile(call, result)

                "copyFileToTree" -> handleCopyFileToTree(call, result)

                "openFileForWriting" -> handleOpenFileForWriting(call, result)

                "openContentUri" -> {
                    openUri(context, call.argument<String>("uri")!!)
                    result.success(null)
                }

                "openGallery" -> {
                    openGallery()
                    result.success(null)
                }

                "openWifiSettings" -> {
                    startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                    result.success(null)
                }

                "enableWifi" -> enableWifi(result)

                "is5GHzBandSupported" -> {
                    val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    result.success(wifiManager?.is5GHzBandSupported == true)
                }

                // compileSdk 36 has no app-scoped band-selection API for local-only hotspot requests.
                "canRequest5GHz" -> result.success(false)

                "getNativePairingLog" -> result.success(PairingNativeLog.read(this))

                "getLastNativeCrash" -> result.success(PairingNativeCrashReport.read(this))

                "startPairingKeepAlive" ->
                    startPairingServiceCommand(PairingForegroundService.ACTION_KEEP_ALIVE, result)

                "stopPairingKeepAlive" ->
                    startPairingServiceCommand(PairingForegroundService.ACTION_STOP, result)

                "startLocalOnlyHotspot" -> startLocalOnlyHotspot(
                    prefer5GHz = call.argument<Boolean>("prefer5GHz") == true,
                    result = result,
                )

                "stopLocalOnlyHotspot" -> {
                    pendingHotspotResult?.error("HOTSPOT_CANCELLED", "Hotspot startup was cancelled.", null)
                    pendingHotspotResult = null
                    startPairingServiceCommand(PairingForegroundService.ACTION_STOP, result)
                }

                "connectToWifiHotspot" -> connectToWifiHotspot(
                    ssid = call.argument<String>("ssid") ?: "",
                    password = call.argument<String>("password") ?: "",
                    result = result,
                )

                "disconnectFromWifiHotspot" -> {
                    val error = disconnectFromWifiHotspot()
                    if (error == null) result.success(null) else result.error("HOTSPOT_DISCONNECT_FAILED", error, null)
                }

                "openAppNotificationSettings" -> {
                    val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    startActivity(intent)
                    result.success(null)
                }

                "openAppPermissionsSettings" -> {
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).setData(Uri.fromParts("package", packageName, null))
                    startActivity(intent)
                    result.success(null)
                }

                "shareInstalledApk" -> result.success(shareInstalledApk())

                "shareTextInvite" -> {
                    shareTextInvite()
                    result.success(null)
                }

                "shareIntentReady" -> {
                    onShareIntentReady()
                    result.success(null)
                }

                "isAnimationsEnabled" -> {
                    result.success(isAnimationsEnabled())
                }

                "getDownloadsDirectory" -> {
                    result.success(getDownloadsDirectory())
                }

                "queryMediaFiles" -> {
                    val category = call.argument<String>("category") ?: "downloads"
                    val offset = (call.argument<Int>("offset") ?: 0).coerceAtLeast(0)
                    val limit = call.argument<Int>("limit")?.coerceIn(1, 200) ?: 0
                    mediaQueryExecutor.execute {
                        try {
                            val files = queryMediaFiles(category, offset, limit)
                            runOnUiThread { result.success(files) }
                        } catch (e: SecurityException) {
                            runOnUiThread { result.error("PERMISSION_DENIED", e.message ?: "Media access was denied", null) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("QUERY_FAILED", e.message ?: "Could not query media files", null) }
                        }
                    }

                }

                "loadMediaThumbnail" -> {
                    val uri = call.argument<String>("uri")
                    val category = call.argument<String>("category")
                    if (uri == null || category == null) result.error("INVALID_ARGUMENT", "Missing URI or category", null)
                    else {
                        mediaQueryExecutor.execute {
                            val thumbnail = loadMediaThumbnail(Uri.parse(uri), category)
                            runOnUiThread { result.success(thumbnail) }
                        }
                    }
                }

                "requestLocalNetworkPermission" -> {
                    if (hasLocalNetworkPermission()) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        requestPermissions(arrayOf(PERMISSION_ACCESS_LOCAL_NETWORK), REQUEST_CODE_LOCAL_NETWORK)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun startLocalOnlyHotspot(prefer5GHz: Boolean, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("HOTSPOT_UNSUPPORTED", "Local-only hotspots require Android 8.0 or newer.", null)
            return
        }
        if (pendingHotspotResult != null || getSharedPreferences("native_pairing", MODE_PRIVATE).getBoolean("service_active", false)) {
            result.error("HOTSPOT_ALREADY_STARTED", "A local-only hotspot is already running or starting.", null)
            return
        }
        if (prefer5GHz) {
            result.error(
                "HOTSPOT_5GHZ_REQUEST_UNSUPPORTED",
                "Android does not provide an app-accessible local-only hotspot API to request a specific band.",
                null,
            )
            return
        }
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            PERMISSION_NEARBY_WIFI_DEVICES
        } else {
            android.Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            pendingHotspotResult = result
            requestPermissions(arrayOf(permission), REQUEST_CODE_LOCAL_ONLY_HOTSPOT)
            return
        }

        pendingHotspotResult = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(PERMISSION_POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(PERMISSION_POST_NOTIFICATIONS), REQUEST_CODE_PAIRING_NOTIFICATIONS)
            return
        }
        startPairingServiceCommand(PairingForegroundService.ACTION_START)
    }

    private fun startPairingServiceCommand(action: String, result: MethodChannel.Result? = null) {
        val intent = Intent(this, PairingForegroundService::class.java).setAction(action)
        if (action == PairingForegroundService.ACTION_STOP) {
            intent.putExtra(PairingForegroundService.EXTRA_STOP_REASON, "dart_stop")
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            if (action != PairingForegroundService.ACTION_START) {
                result?.success(null)
            }
        } catch (error: SecurityException) {
            handlePairingServiceCommandError(action, error, result)
        } catch (error: RuntimeException) {
            handlePairingServiceCommandError(action, error, result)
        }
    }

    private fun handlePairingServiceCommandError(action: String, error: RuntimeException, result: MethodChannel.Result?) {
        val message = error.message
            ?: "Android could not ${if (action == PairingForegroundService.ACTION_STOP) "stop" else "start"} the pairing service."
        if (action == PairingForegroundService.ACTION_START) {
            PairingNativeLog.append(this, "service_started", "failed")
            pendingHotspotResult?.error("HOTSPOT_SERVICE_FAILED", message, null)
            pendingHotspotResult = null
        } else if (action == PairingForegroundService.ACTION_STOP) {
            PairingNativeLog.append(this, "teardown_reason", "stop_failed")
            result?.error("HOTSPOT_STOP_FAILED", message, null)
        } else {
            PairingNativeLog.append(this, "service_started", "failed")
            result?.error("PAIRING_SERVICE_FAILED", message, null)
        }
    }

    private fun connectToWifiHotspot(ssid: String, password: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            completeWifiConnect(result, "unsupported", "Automatic Wi-Fi connection requires Android 8.0 or newer.")
            return
        }
        if (ssid.isBlank() || password.isBlank()) {
            completeWifiConnect(result, "failed", "Wi-Fi name and password are required.")
            return
        }
        if (pendingWifiHotspotResult != null || wifiHotspotNetworkCallback != null || legacyWifiNetworkId != null) {
            val disconnectError = disconnectFromWifiHotspot()
            if (disconnectError != null) {
                completeWifiConnect(result, "failed", disconnectError)
                return
            }
        }
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            PERMISSION_NEARBY_WIFI_DEVICES
        } else {
            android.Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            pendingWifiHotspotResult = result
            pendingWifiHotspotSsid = ssid
            pendingWifiHotspotPassword = password
            requestPermissions(arrayOf(permission), REQUEST_CODE_WIFI_HOTSPOT)
            return
        }

        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (connectivityManager == null) {
            completeWifiConnect(result, "unsupported", "Android network connectivity is unavailable.")
            return
        }
        PairingNativeLog.append(this, "network_request_result", "started")
        pendingWifiHotspotResult = result
        pendingWifiHotspotSsid = ssid
        pendingWifiHotspotPassword = password
        wifiHotspotTimeout = Runnable {
            if (pendingWifiHotspotResult === result) {
                PairingNativeLog.append(this, "network_request_result", "timeout")
                finishWifiConnect("timeout", "Timed out while connecting to the Wi-Fi hotspot.")
            }
        }.also { Handler(Looper.getMainLooper()).postDelayed(it, WIFI_CONNECT_TIMEOUT_MS) }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val specifier = WifiNetworkSpecifier.Builder().setSsid(ssid).setWpa2Passphrase(password).build()
                val request = NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .setNetworkSpecifier(specifier)
                    .build()
                val callback = object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        if (pendingWifiHotspotResult !== result) return
                        PairingNativeLog.append(this@MainActivity, "network_request_result", "available")
                        if (bindWifiProcessToNetwork(connectivityManager, network)) {
                            PairingNativeLog.append(this@MainActivity, "bind_result", "success")
                            wifiHotspotNetworkCallback = this
                            finishWifiConnect("success", "Connected to the QR hotspot.")
                        } else {
                            PairingNativeLog.append(this@MainActivity, "bind_result", "failed")
                            finishWifiConnect("failed", "Android could not bind the app to the Wi-Fi hotspot.")
                        }
                    }

                    override fun onLost(network: Network) {
                        unbindIfLostNetwork(connectivityManager, network)
                    }

                    override fun onUnavailable() {
                        if (pendingWifiHotspotResult === result) {
                            PairingNativeLog.append(this@MainActivity, "network_request_result", "unavailable")
                            finishWifiConnect("user_denied", "The Wi-Fi connection request was declined or unavailable.")
                        }
                    }
                }
                wifiHotspotNetworkCallback = callback
                connectivityManager.requestNetwork(request, callback)
            } else {
                connectLegacyWifiHotspot(ssid, password, connectivityManager, result)
            }
        } catch (error: SecurityException) {
            PairingNativeLog.append(this, "network_request_result", "permission_denied")
            finishWifiConnect("user_denied", error.message ?: "Android denied permission to connect to Wi-Fi.")
        } catch (error: RuntimeException) {
            PairingNativeLog.append(this, "network_request_result", "failed")
            finishWifiConnect("failed", error.message ?: "Android could not request the Wi-Fi network.")
        }
    }

    @Suppress("DEPRECATION")
    private fun connectLegacyWifiHotspot(
        ssid: String,
        password: String,
        connectivityManager: ConnectivityManager,
        result: MethodChannel.Result,
    ) {
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifiManager == null) {
            finishWifiConnect("unsupported", "Wi-Fi is unavailable on this device.")
            return
        }
        val quotedSsid = "\"$ssid\""
        val configuration = WifiConfiguration().apply {
            SSID = quotedSsid
            preSharedKey = "\"$password\""
            allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK)
        }
        if (wifiManager.configuredNetworks?.any { it.SSID == quotedSsid } == true) {
            finishWifiConnect("failed", "This Wi-Fi name is already saved. Connect manually to avoid changing its saved password.")
            return
        }
        val networkId = wifiManager.addNetwork(configuration)
        if (networkId < 0) {
            finishWifiConnect("failed", "Android could not add the QR hotspot configuration.")
            return
        }
        legacyWifiNetworkId = networkId
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (pendingWifiHotspotResult !== result) return
                val connectedSsid = wifiManager.connectionInfo?.ssid?.removeSurrounding("\"")
                if (connectedSsid != ssid) return
                PairingNativeLog.append(this@MainActivity, "network_request_result", "available")
                if (bindWifiProcessToNetwork(connectivityManager, network)) {
                    PairingNativeLog.append(this@MainActivity, "bind_result", "success")
                    wifiHotspotNetworkCallback = this
                    finishWifiConnect("success", "Connected to the QR hotspot.")
                } else {
                    PairingNativeLog.append(this@MainActivity, "bind_result", "failed")
                    finishWifiConnect("failed", "Android could not bind the app to the Wi-Fi hotspot.")
                }
            }

            override fun onLost(network: Network) {
                unbindIfLostNetwork(connectivityManager, network)
            }
        }
        wifiHotspotNetworkCallback = callback
        connectivityManager.registerDefaultNetworkCallback(callback)
        if (!wifiManager.enableNetwork(networkId, true) || !wifiManager.reconnect()) {
            PairingNativeLog.append(this, "network_request_result", "failed")
            finishWifiConnect("failed", "Android could not enable the QR hotspot configuration.")
        }
    }

    private fun completeWifiConnect(result: MethodChannel.Result, code: String, message: String) {
        result.success(mapOf("code" to code, "message" to message))
    }

    private fun finishWifiConnect(code: String, message: String) {
        val result = pendingWifiHotspotResult ?: return
        pendingWifiHotspotResult = null
        pendingWifiHotspotSsid = null
        pendingWifiHotspotPassword = null
        wifiHotspotTimeout?.let { Handler(Looper.getMainLooper()).removeCallbacks(it) }
        wifiHotspotTimeout = null
        var resultCode = code
        var resultMessage = message
        if (code != "success") {
            unregisterWifiCallback()
            val unbindError = unbindWifiProcessNetwork()
            val removeError = removeLegacyWifiConfiguration()
            val cleanupError = unbindError ?: removeError
            if (cleanupError != null) {
                PairingNativeLog.append(this, "bind_result", "unbind_failed")
                resultCode = "failed"
                resultMessage = "$message $cleanupError"
            }
        }
        result.success(mapOf("code" to resultCode, "message" to resultMessage))
    }

    private fun unbindIfLostNetwork(connectivityManager: ConnectivityManager, network: Network) {
        try {
            if (connectivityManager.boundNetworkForProcess == network) {
                if (connectivityManager.bindProcessToNetwork(null)) {
                    PairingNativeLog.append(this, "teardown_reason", "receiver_network_lost")
                    sendBroadcast(Intent(PairingForegroundService.ACTION_PAIRING_DISCONNECTED).setPackage(packageName))
                } else {
                    PairingNativeLog.append(this, "bind_result", "unbind_failed")
                }
            }
        } catch (_: SecurityException) {
            PairingNativeLog.append(this, "bind_result", "unbind_permission_denied")
        } catch (_: RuntimeException) {
            PairingNativeLog.append(this, "bind_result", "unbind_failed")
        }
    }

    private fun bindWifiProcessToNetwork(connectivityManager: ConnectivityManager, network: Network): Boolean {
        return try {
            connectivityManager.bindProcessToNetwork(network)
        } catch (_: SecurityException) {
            PairingNativeLog.append(this, "bind_result", "permission_denied")
            false
        } catch (_: RuntimeException) {
            PairingNativeLog.append(this, "bind_result", "failed")
            false
        }
    }

    private fun unbindWifiProcessNetwork(): String? {
        val connectivityManager = getSystemService(ConnectivityManager::class.java) ?: return null
        return try {
            if (connectivityManager.bindProcessToNetwork(null)) null else "Android could not unbind the app from the Wi-Fi network."
        } catch (error: SecurityException) {
            error.message ?: "Android denied permission to unbind the Wi-Fi network."
        } catch (error: RuntimeException) {
            error.message ?: "Android could not unbind the Wi-Fi network."
        }
    }

    private fun disconnectFromWifiHotspot(): String? {
        if (pendingWifiHotspotResult != null) {
            finishWifiConnect("failed", "The Wi-Fi connection was cancelled.")
        }
        unregisterWifiCallback()
        val error = unbindWifiProcessNetwork() ?: removeLegacyWifiConfiguration()
        PairingNativeLog.append(this, "teardown_reason", if (error == null) "receiver_disconnect" else "receiver_disconnect_failed")
        return error
    }

    @Suppress("DEPRECATION")
    private fun removeLegacyWifiConfiguration(): String? {
        val networkId = legacyWifiNetworkId ?: return null
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifiManager == null) return "Wi-Fi is unavailable while cleaning up the connection."
        return try {
            if (!wifiManager.removeNetwork(networkId)) {
                "Android could not remove the temporary QR hotspot configuration."
            } else {
                wifiManager.reconnect()
                legacyWifiNetworkId = null
                null
            }
        } catch (error: SecurityException) {
            error.message ?: "Android denied cleanup of the temporary Wi-Fi configuration."
        } catch (error: RuntimeException) {
            error.message ?: "Android could not clean up the temporary Wi-Fi configuration."
        }
    }

    private fun unregisterWifiCallback() {
        val connectivityManager = getSystemService(ConnectivityManager::class.java)
        wifiHotspotNetworkCallback?.let { callback ->
            try {
                connectivityManager?.unregisterNetworkCallback(callback)
            } catch (_: IllegalArgumentException) {
            }
        }
        wifiHotspotNetworkCallback = null
        wifiHotspotTimeout?.let { Handler(Looper.getMainLooper()).removeCallbacks(it) }
        wifiHotspotTimeout = null
    }

    private fun enableWifi(result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startActivity(Intent(Settings.Panel.ACTION_WIFI))
                result.success(mapOf("success" to true, "path" to "settings_panel"))
                return
            }
            @Suppress("DEPRECATION")
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiManager == null) {
                result.success(mapOf("success" to false, "path" to "set_wifi_enabled", "message" to "Wi-Fi is unavailable."))
                return
            }
            @Suppress("DEPRECATION")
            val enabled = wifiManager.isWifiEnabled || wifiManager.setWifiEnabled(true)
            result.success(mapOf("success" to enabled, "path" to "set_wifi_enabled"))
        } catch (error: SecurityException) {
            result.success(mapOf("success" to false, "path" to "permission_denied", "message" to (error.message ?: "Android denied Wi-Fi access.")))
        } catch (error: RuntimeException) {
            result.success(mapOf("success" to false, "path" to "failed", "message" to (error.message ?: "Android could not enable Wi-Fi.")))
        }
    }

    private fun shareInstalledApk(): Boolean {
        return try {
            val apk = File(applicationInfo.sourceDir)
            if (!apk.canRead()) return false
            val sharedApk = File(cacheDir, "share/OmniDrop.apk")
            sharedApk.parentFile?.mkdirs()
            apk.copyTo(sharedApk, overwrite = true)
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", sharedApk)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "application/vnd.android.package-archive"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Share OmniDrop"))
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun shareTextInvite() {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, "Install OmniDrop for private local file sharing: https://omnidrop.app")
        }
        startActivity(Intent.createChooser(intent, "Share OmniDrop"))
    }

    /// Android 17+ gates local network access behind a runtime permission; older versions grant it implicitly.
    private fun hasLocalNetworkPermission(): Boolean {
        if (Build.VERSION.SDK_INT < API_LEVEL_ANDROID_17) {
            return true
        }
        return checkSelfPermission(PERMISSION_ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE_LOCAL_NETWORK) {
            pendingPermissionResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingPermissionResult = null
        } else if (requestCode == REQUEST_CODE_LOCAL_ONLY_HOTSPOT) {
            val result = pendingHotspotResult
            pendingHotspotResult = null
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED && result != null) {
                startLocalOnlyHotspot(prefer5GHz = false, result = result)
            } else {
                PairingNativeLog.append(this, "hotspot_start_result", "permission_denied")
                result?.error("HOTSPOT_PERMISSION_DENIED", "Permission to start a local-only hotspot was denied.", null)
            }
        } else if (requestCode == REQUEST_CODE_WIFI_HOTSPOT) {
            val result = pendingWifiHotspotResult
            val ssid = pendingWifiHotspotSsid
            val password = pendingWifiHotspotPassword
            pendingWifiHotspotResult = null
            pendingWifiHotspotSsid = null
            pendingWifiHotspotPassword = null
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED && result != null && ssid != null && password != null) {
                connectToWifiHotspot(ssid = ssid, password = password, result = result)
            } else {
                PairingNativeLog.append(this, "network_request_result", "permission_denied")
                result?.success(mapOf("code" to "user_denied", "message" to "Wi-Fi permission was denied."))
            }
        } else if (requestCode == REQUEST_CODE_PAIRING_NOTIFICATIONS) {
            val result = pendingHotspotResult
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED && result != null) {
                startPairingServiceCommand(PairingForegroundService.ACTION_START)
            } else {
                pendingHotspotResult = null
                PairingNativeLog.append(this, "hotspot_start_result", "notification_permission_denied")
                result?.error("HOTSPOT_NOTIFICATION_PERMISSION_DENIED", "Allow notifications to keep the pairing hotspot active.", null)
            }
        }
    }

    /// Absolute path of the shared "Download" directory (usually /storage/emulated/0/Download).
    @Suppress("DEPRECATION")
    private fun getDownloadsDirectory(): String {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
    }

    private fun queryMediaFiles(category: String, offset: Int, limit: Int): List<Map<String, Any?>> {
        val documents = category == "documents"
        val collection = when (category) {
            "images" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            "videos" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            "downloads" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL)
            } else {
                MediaStore.Files.getContentUri("external")
            }
            else -> MediaStore.Files.getContentUri("external")
        }
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.MIME_TYPE,
        )
        val supportedMimeTypes = arrayOf(
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "text/plain",
            "text/csv",
            "application/epub+zip",
            "application/zip",
        )
        val selection = when {
            documents -> "${MediaStore.MediaColumns.MIME_TYPE} IN (${supportedMimeTypes.joinToString(",") { "?" }})"
            category == "downloads" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
            category == "downloads" -> "${MediaStore.MediaColumns.DATA} LIKE ?"
            else -> null
        }
        val selectionArgs = when {
            documents -> supportedMimeTypes
            category == "downloads" -> arrayOf(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) "Download/%" else "${getDownloadsDirectory()}%")
            else -> null
        }
        val sortOrder = "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"
        val files = mutableListOf<Map<String, Any?>>()
        val cursor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val queryArgs = Bundle().apply {
                if (selection != null) putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                if (selectionArgs != null) putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selectionArgs)
                putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, sortOrder)
                if (limit > 0) putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
                if (offset > 0) putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
            }
            contentResolver.query(collection, projection, queryArgs, null)
        } else {
            val paginatedSortOrder = if (limit > 0) "$sortOrder LIMIT $limit OFFSET $offset" else sortOrder
            contentResolver.query(collection, projection, selection, selectionArgs, paginatedSortOrder)
        } ?: return files
        cursor.use {
            val idColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val modifiedColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            while (it.moveToNext() && (limit <= 0 || files.size < limit)) {
                val id = it.getLong(idColumn)
                val modified = it.getLong(modifiedColumn)
                files.add(
                    FileInfo(
                        name = it.getString(nameColumn) ?: "",
                        size = it.getLong(sizeColumn).coerceAtLeast(0),
                        uri = ContentUris.withAppendedId(collection, id).toString(),
                        lastModified = if (modified > 0) Date(modified * 1000).time.toRfc3339() else null,
                    ).toMap(),
                )
            }
        }
        return files
    }

    @Suppress("DEPRECATION")
    private fun loadMediaThumbnail(uri: Uri, category: String): ByteArray? {
        return try {
            val bitmap = when {
                category == "audio" -> {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(this, uri)
                        val embeddedArt = retriever.embeddedPicture ?: return null
                        decodeEmbeddedArtwork(embeddedArt)
                    } finally {
                        retriever.release()
                    }
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> contentResolver.loadThumbnail(uri, Size(256, 256), null)
                category == "images" -> MediaStore.Images.Thumbnails.getThumbnail(
                    contentResolver,
                    ContentUris.parseId(uri),
                    MediaStore.Images.Thumbnails.MINI_KIND,
                    null,
                )
                category == "videos" -> MediaStore.Video.Thumbnails.getThumbnail(
                    contentResolver,
                    ContentUris.parseId(uri),
                    MediaStore.Video.Thumbnails.MINI_KIND,
                    null,
                )
                else -> null
            } ?: return null
            ByteArrayOutputStream().use { output ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 78, output)
                bitmap.recycle()
                output.toByteArray()
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun hasRemovableStorage(): Boolean {
        val storageManager = getSystemService(Context.STORAGE_SERVICE) as StorageManager
        return storageManager.storageVolumes.any { it.isRemovable && it.state == Environment.MEDIA_MOUNTED }
    }

    private fun decodeEmbeddedArtwork(data: ByteArray): Bitmap? {
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        var sampleSize = 1
        while (bounds.outWidth / sampleSize > 256 || bounds.outHeight / sampleSize > 256) {
            sampleSize *= 2
        }
        return android.graphics.BitmapFactory.decodeByteArray(
            data,
            0,
            data.size,
            android.graphics.BitmapFactory.Options().apply { inSampleSize = sampleSize },
        )
    }

    private fun getStorageTree(storage: String): Uri? {
        val preferences = getSharedPreferences("storage", MODE_PRIVATE)
        val key = if (storage == "sd") "tree_sd" else "tree_internal"
        val saved = preferences.getString(key, null)?.let(Uri::parse)
        if (saved != null && contentResolver.persistedUriPermissions.any { it.uri == saved && it.isReadPermission && it.isWritePermission }) {
            ensureOmniDropFolders(saved)
            return saved
        }
        if (saved != null) preferences.edit().remove(key).apply()

        val externalTree = contentResolver.persistedUriPermissions.firstOrNull { permission ->
            if (!permission.isReadPermission || !permission.isWritePermission) return@firstOrNull false
            val id = runCatching { DocumentsContract.getTreeDocumentId(permission.uri) }.getOrNull() ?: return@firstOrNull false
            if (storage == "sd") id.substringBefore(':') != "primary" else id.substringBefore(':') == "primary"
        }?.uri ?: return null
        preferences.edit().putString(key, externalTree.toString()).apply()
        ensureOmniDropFolders(externalTree)
        return externalTree
    }

    private fun ensureOmniDropFolders(treeUri: Uri) {
        val root = DocumentFile.fromTreeUri(this, treeUri) ?: throw IllegalStateException("Could not open storage tree")
        val omniDrop = root.findFile("OmniDrop")?.takeIf { it.isDirectory } ?: root.createDirectory("OmniDrop")
            ?: throw IllegalStateException("Could not create OmniDrop folder")
        for (name in listOf("image", "video", "audio", "app", "folder", "other")) {
            if (omniDrop.findFile(name)?.isDirectory != true && omniDrop.createDirectory(name) == null) {
                throw IllegalStateException("Could not create OmniDrop/$name folder")
            }
        }
    }

    private fun isAnimationsEnabled() : Boolean {
        return Settings.Global.getFloat(this.getContentResolver(),
            Settings.Global.ANIMATOR_DURATION_SCALE, 1.0f) != 0.0f;
    }

    private fun handleGetFileDescriptor(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        try {
            val parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "r")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            // Ownership of the detached descriptor is transferred to the caller. It must be
            // closed by Rust (or whichever native consumer receives it) after use.
            parcelFileDescriptor.use {
                result.success(it.detachFd())
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: "Failed to open content URI", null)
        }
    }

    /// Creates a new file inside a SAF directory and opens it for writing.
    ///
    /// Returns the URI of the created document (Android may rename the file on
    /// collisions) and an owned writable file descriptor. The descriptor must be
    /// closed by the native consumer it is passed to.
    private fun handleCreateFile(call: MethodCall, result: MethodChannel.Result) {
        val parentUriString = call.argument<String>("parentUri")
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        if (parentUriString == null || fileName == null) {
            result.error("INVALID_ARGUMENT", "Missing parentUri or fileName", null)
            return
        }

        try {
            val parentUri = Uri.parse(parentUriString)

            // A pure tree URI (content://…/tree/X) must be converted to its
            // document form before it can be used as a parent document.
            val segments = parentUri.pathSegments
            val parentDocumentUri = if (segments.size == 2 && segments[0] == "tree") {
                DocumentsContract.buildDocumentUriUsingTree(
                    parentUri,
                    DocumentsContract.getTreeDocumentId(parentUri)
                )
            } else {
                parentUri
            }

            val parent = findTreeDocument(parentDocumentUri)
            val documentUri = parent?.createFile(mimeType, fileName)?.uri
            if (documentUri == null) {
                result.error("CREATE_FAILED", "Could not create $fileName in $parentUriString", null)
                return
            }

            // "wt" is write + truncate: the document is new, unless the provider
            // handed out an existing one instead of creating a second document.
            val parcelFileDescriptor = contentResolver.openFileDescriptor(documentUri, "wt")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            parcelFileDescriptor.use {
                result.success(
                    mapOf(
                        "uri" to documentUri.toString(),
                        "fd" to it.detachFd(),
                    )
                )
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("CREATE_FAILED", e.message ?: "Failed to create file", null)
        }
    }

    /// Opens an existing document created by [handleCreateFile] for writing,
    /// discarding its current content.
    ///
    /// Used to write a file again after a failed attempt, so that it keeps its
    /// name instead of being created a second time under a numbered one.
    ///
    /// Returns an owned writable file descriptor. It stays open after this call
    /// and must be closed by the native consumer it is passed to.
    private fun handleOpenFileForWriting(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        try {
            // "wt" is write + truncate. A document provider may ignore the
            // truncation, so the writer additionally shortens the file itself.
            val parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "wt")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            parcelFileDescriptor.use {
                result.success(it.detachFd())
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: "Failed to open content URI", null)
        }
    }

    private fun handleCopyFileToTree(call: MethodCall, result: MethodChannel.Result) {
        val parentUri = call.argument<String>("parentUri")?.let(Uri::parse)
        val sourcePath = call.argument<String>("sourcePath")
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        if (parentUri == null || sourcePath == null || fileName == null) {
            result.error("INVALID_ARGUMENT", "Missing parentUri, sourcePath, or fileName", null)
            return
        }

        try {
            val parent = findTreeDocument(parentUri) ?: throw IllegalStateException("Could not find the destination folder")
            val documentUri = parent.createFile(mimeType, fileName)?.uri ?: throw IllegalStateException("Could not create $fileName")
            val output = contentResolver.openOutputStream(documentUri, "wt")
                ?: throw IllegalStateException("Could not open $fileName for writing")
            FileInputStream(sourcePath).use { input -> output.use { input.copyTo(it) } }
            result.success(documentUri.toString())
        } catch (e: Exception) {
            result.error("COPY_FAILED", e.message ?: "Could not copy file to storage", null)
        }
    }

    private fun openDirectoryPicker(onlyPath: Boolean) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        startActivityForResult(
            intent,
            if (onlyPath) REQUEST_CODE_PICK_DIRECTORY_PATH else REQUEST_CODE_PICK_DIRECTORY
        )
    }

    private fun openFolderTreePicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_CODE_PICK_FOLDER_TREE)
    }

    private fun openStorageTreePicker(storage: String) {
        pendingStorageLocation = storage
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val initialUri = if (storage == "sd") {
                    val volume = (getSystemService(Context.STORAGE_SERVICE) as StorageManager).storageVolumes
                        .firstOrNull { it.isRemovable && it.state == Environment.MEDIA_MOUNTED }
                    volume?.uuid?.let { Uri.parse("content://com.android.externalstorage.documents/root/$it") }
                } else {
                    Uri.parse("content://com.android.externalstorage.documents/root/primary")
                }
                if (initialUri != null) putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
            }
        }
        startActivityForResult(intent, REQUEST_CODE_PICK_STORAGE_TREE)
    }

    private fun openFilePicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra("multi-pick", true)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_CODE_PICK_FILE)
    }

    @SuppressLint("WrongConstant")
    @Override
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode == Activity.RESULT_CANCELED) {
            if (requestCode == REQUEST_CODE_PICK_FOLDER_TREE || requestCode == REQUEST_CODE_PICK_STORAGE_TREE) {
                if (requestCode == REQUEST_CODE_PICK_STORAGE_TREE && pendingStoragePickerForSetting) pendingResult?.success(false)
                else pendingResult?.success(null)
            } else {
                pendingResult?.error("CANCELED", "Canceled", null)
            }
            pendingResult = null
            return
        }

        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingResult?.error("Error $resultCode", "Failed to access directory or file", null)
            pendingResult = null
            return
        }

        when (requestCode) {
            REQUEST_CODE_PICK_DIRECTORY -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)

                    val files = mutableListOf<FileInfo>()
                    listFiles(uri, files)
                    val resultData = PickDirectoryResult(uri.toString(), files)
                    pendingResult?.success(resultData.toMap())
                    pendingResult = null
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_DIRECTORY_PATH -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                    pendingResult?.success(uri.toString())
                    pendingResult = null
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_FOLDER_TREE -> {
                val uri = data.data
                val takeFlags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                    getSharedPreferences("storage", MODE_PRIVATE).edit().putString("tree_internal", uri.toString()).apply()
                    ensureOmniDropFolders(uri)
                    pendingResult?.success(uri.toString())
                } else {
                    pendingResult?.error("Error", "Failed to access folder", null)
                }
                pendingResult = null
            }

            REQUEST_CODE_PICK_STORAGE_TREE -> {
                val uri = data.data
                val takeFlags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    try {
                        val storageId = runCatching { DocumentsContract.getTreeDocumentId(uri).substringBefore(':') }.getOrNull()
                        val externalStorageProvider = uri.authority == "com.android.externalstorage.documents"
                        val wrongVolume = !externalStorageProvider ||
                            pendingStorageLocation == "sd" && storageId == "primary" ||
                            pendingStorageLocation == "internal" && storageId != "primary"
                        if (wrongVolume) {
                            pendingResult?.success(if (pendingStoragePickerForSetting) false else null)
                            pendingResult = null
                            pendingStoragePickerForSetting = false
                            return
                        }
                        contentResolver.takePersistableUriPermission(uri, takeFlags)
                        ensureOmniDropFolders(uri)
                        val preferences = getSharedPreferences("storage", MODE_PRIVATE)
                        val treeKey = if (pendingStorageLocation == "sd") "tree_sd" else "tree_internal"
                        preferences.edit().putString(treeKey, uri.toString()).putString("save_location", pendingStorageLocation).apply()
                        pendingResult?.success(if (pendingStoragePickerForSetting) true else uri.toString())
                    } catch (e: Exception) {
                        pendingResult?.error("STORAGE_SETUP_FAILED", e.message ?: "Could not initialize storage", null)
                    }
                } else {
                    pendingResult?.success(false)
                }
                pendingResult = null
                pendingStoragePickerForSetting = false
            }

            REQUEST_CODE_PICK_FILE -> {
                val uriList: List<Uri> = when {
                    data.clipData != null -> {
                        val clipData = data.clipData
                        val uris = mutableListOf<Uri>()
                        for (i in 0 until clipData!!.itemCount) {
                            uris.add(clipData.getItemAt(i).uri)
                        }
                        uris
                    }

                    data.data != null -> listOf(data.data!!)
                    else -> {
                        pendingResult?.error("Error", "Failed to access file", null)
                        return
                    }
                }

                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

                val resultList = mutableListOf<FileInfo>()
                for (uri in uriList) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                    val documentFile = FastDocumentFile.fromDocumentUri(this, uri)
                    if (documentFile == null) {
                        pendingResult?.error("Error", "Failed to access file", null)
                        return
                    }
                    resultList.add(
                        FileInfo(
                            name = documentFile.name,
                            size = documentFile.size,
                            uri = uri.toString(),
                            lastModified = documentFile.lastModified?.toRfc3339(),
                        )
                    )
                }

                pendingResult?.success(resultList.map { it.toMap() })
                pendingResult = null
            }
        }
    }

    private fun listFiles(uri: Uri, files: MutableList<FileInfo>) {
        val pickedDir: FastDocumentFile = FastDocumentFile.fromTreeUri(this, uri)

        for (file in pickedDir.listFiles()) {
            if (file.isDirectory) {
                // Recursive call
                listFiles(file.uri, files)
            } else if (file.isFile) {
                files.add(
                    FileInfo(
                        name = file.name,
                        size = file.size,
                        uri = file.uri.toString(),
                        lastModified = file.lastModified?.toRfc3339(),
                    ),
                )
            }
        }
    }

    private fun listTreeEntries(uri: Uri): List<Map<String, Any?>> {
        val treeUri = Uri.parse(uri.toString().substringBefore("/document/"))
        val treeDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val documentId = if (DocumentsContract.isDocumentUri(this, uri)) {
            DocumentsContract.getDocumentId(uri)
        } else {
            treeDocumentId
        }
        require(isWithinTree(treeDocumentId, documentId)) { "Folder URI is outside the granted storage tree" }

        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, documentId)
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        val cursor = contentResolver.query(childrenUri, columns, null, null, null)
            ?: throw IllegalStateException("The storage provider could not read this folder")

        return cursor.use { childCursor ->
            val entries = mutableListOf<Map<String, Any?>>()
            while (childCursor.moveToNext()) {
                val mime = childCursor.getString(0)
                val childDocumentId = childCursor.getString(1)
                val name = childCursor.getString(2) ?: ""
                val size = if (childCursor.isNull(3)) 0L else childCursor.getLong(3).coerceAtLeast(0L)
                val modified = if (childCursor.isNull(4)) null else childCursor.getLong(4).takeIf { it > 0L }?.toRfc3339()
                val childUri = DocumentsContract.buildDocumentUriUsingTree(uri, childDocumentId)
                entries.add(
                    mapOf(
                        "name" to name,
                        "size" to size,
                        "uri" to childUri.toString(),
                        "lastModified" to modified,
                        "isDirectory" to (mime == DocumentsContract.Document.MIME_TYPE_DIR),
                    ),
                )
            }
            entries
        }
    }

    private fun listTreeFiles(uri: Uri, parentPath: String): List<Map<String, Any?>> {
        val root = findTreeDocument(uri) ?: throw IllegalStateException("Could not resolve the selected folder")
        return listDocumentFiles(root, parentPath)
    }

    private fun listDocumentFiles(parent: DocumentFile, parentPath: String): List<Map<String, Any?>> {
        val files = mutableListOf<Map<String, Any?>>()
        for (entry in parent.listFiles()) {
            val name = entry.name ?: ""
            val relativePath = if (parentPath.isEmpty()) name else "$parentPath/$name"
            if (entry.isDirectory) {
                files.addAll(listDocumentFiles(entry, relativePath))
            } else if (entry.isFile && name.isNotEmpty()) {
                files.add(
                    FileInfo(
                        name = relativePath,
                        size = entry.length().coerceAtLeast(0L),
                        uri = entry.uri.toString(),
                        lastModified = entry.lastModified().takeIf { it > 0L }?.toRfc3339(),
                    ).toMap(),
                )
            }
        }
        return files
    }

    private fun handleCreateDirectory(call: MethodCall, result: MethodChannel.Result) {
        val documentUri = Uri.parse(call.argument<String>("documentUri")!!)
        val directoryName = call.argument<String>("directoryName")!!
        try {
            val parent = findTreeDocument(documentUri) ?: throw IllegalStateException("Could not find the parent folder")
            val existing = parent.findFile(directoryName)
            if (existing?.isDirectory == true || parent.createDirectory(directoryName) != null) {
                result.success(null)
            } else {
                result.error("CREATE_FAILED", "Could not create folder $directoryName", null)
            }
        } catch (e: Exception) {
            result.error("CREATE_FAILED", e.message ?: "Could not create folder", null)
        }
    }

    private fun findTreeDocument(uri: Uri): DocumentFile? {
        val treeUri = Uri.parse(uri.toString().substringBefore("/document/"))
        val treeDocumentId = runCatching { DocumentsContract.getTreeDocumentId(treeUri) }.getOrNull() ?: return null
        val targetDocumentId = if (DocumentsContract.isDocumentUri(this, uri)) {
            DocumentsContract.getDocumentId(uri)
        } else {
            treeDocumentId
        }
        if (!isWithinTree(treeDocumentId, targetDocumentId)) return null

        var current = DocumentFile.fromTreeUri(this, treeUri) ?: return null
        val relativePath = if (targetDocumentId == treeDocumentId) {
            ""
        } else if (treeDocumentId.endsWith(':')) {
            targetDocumentId.removePrefix(treeDocumentId).trimStart('/')
        } else {
            targetDocumentId.removePrefix("$treeDocumentId/").trimStart('/')
        }
        for (name in relativePath.split('/').filter { it.isNotEmpty() }) {
            current = current.findFile(name) ?: return null
        }
        return current
    }

    private fun isWithinTree(treeDocumentId: String, targetDocumentId: String): Boolean {
        if (targetDocumentId == treeDocumentId) return true
        return if (treeDocumentId.endsWith(':')) {
            targetDocumentId.startsWith(treeDocumentId)
        } else {
            targetDocumentId.startsWith("$treeDocumentId/")
        }
    }

    private fun openGallery() {
        val intent = Intent()
        intent.action = Intent.ACTION_VIEW
        intent.type = "image/*"
        startActivity(intent)
    }
}

data class PickDirectoryResult(
    val directoryUri: String,
    val files: List<FileInfo>,
) {
    fun toMap(): Map<String, Any> {
        return mapOf(
            "directoryUri" to directoryUri,
            "files" to files.map { it.toMap() }
        )
    }
}

data class FileInfo(
    val name: String,
    val size: Long,
    val uri: String,
    val lastModified: String?
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "name" to name,
            "size" to size,
            "uri" to uri,
            "lastModified" to lastModified
        )
    }
}

/// Formats milliseconds since epoch as an RFC 3339 string in UTC.
private fun Long.toRfc3339(): String {
    val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
    format.timeZone = TimeZone.getTimeZone("UTC")
    return format.format(Date(this))
}
