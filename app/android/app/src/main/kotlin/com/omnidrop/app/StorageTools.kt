package com.omnidrop.app

import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService

/**
 * Native helpers for the OmniDrop file browser. Channel contract (Dart side):
 *
 *  getStorageStats          -> {total, free, photos, videos, audio, docs}  (bytes, Long)
 *  deleteFiles {paths}      -> {deleted: [..], failed: [..], cancelled: Boolean}
 *  uninstallApp {package}   -> {launched: true}   (system uninstall screen; errors: SELF, SYSTEM_APP, NOT_INSTALLED)
 *  findApkFiles             -> [{path, name, size, modified}]
 *  getApkInfo {path}        -> {package, label, versionName, versionCode, state, icon(PNG bytes)}
 *                              state: not_installed | update | installed
 *  installApk {path}        -> {launched: true}   (error INSTALL_NOT_ALLOWED -> call openInstallSettings)
 *  canInstallPackages       -> Boolean
 *  openInstallSettings      -> true
 *
 * Every result is delivered exactly once, on the main thread.
 */
internal class StorageTools(
    private val activity: Activity,
    private val executor: ExecutorService,
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    private var pendingDelete: MethodChannel.Result? = null
    private var pendingDeleted: List<String> = emptyList()
    private var pendingConfirm: List<String> = emptyList()
    private var pendingFailed: List<String> = emptyList()

    companion object {
        private const val REQUEST_DELETE = 7421
    }

    fun handle(call: MethodCall, rawResult: MethodChannel.Result) {
        val result = OnceResult(rawResult)
        try {
            when (call.method) {
                "getStorageStats" -> getStorageStats(result)
                "deleteFiles" -> deleteFiles(call, result)
                "uninstallApp" -> uninstallApp(call, result)
                "findApkFiles" -> findApkFiles(result)
                "getApkInfo" -> getApkInfo(call, result)
                "installApk" -> installApk(call, result)
                "canInstallPackages" -> result.success(activity.packageManager.canRequestPackageInstalls())
                "openInstallSettings" -> openInstallSettings(result)
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("NATIVE_ERROR", t.message ?: t.javaClass.simpleName, null)
        }
    }

    /** Returns true when the result belongs to a delete confirmation started here. */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_DELETE) return false
        val result = pendingDelete ?: return true
        pendingDelete = null
        val deleted = ArrayList<String>(pendingDeleted)
        val failed = ArrayList<String>(pendingFailed)
        val confirmed = resultCode == Activity.RESULT_OK
        if (confirmed) deleted.addAll(pendingConfirm) else failed.addAll(pendingConfirm)
        val out = HashMap<String, Any>()
        out["deleted"] = deleted
        out["failed"] = failed
        out["cancelled"] = !confirmed
        result.success(out)
        return true
    }

    // ---------------------------------------------------------------- storage

    private fun getStorageStats(result: MethodChannel.Result) {
        executor.execute {
            try {
                val stat = StatFs(Environment.getExternalStorageDirectory().absolutePath)
                val total = stat.blockCountLong * stat.blockSizeLong
                val free = stat.availableBlocksLong * stat.blockSizeLong
                var photos = 0L
                var videos = 0L
                var audio = 0L
                var docs = 0L
                val uri = MediaStore.Files.getContentUri("external")
                val projection = arrayOf(
                    MediaStore.Files.FileColumns.SIZE,
                    MediaStore.Files.FileColumns.MEDIA_TYPE,
                    MediaStore.Files.FileColumns.MIME_TYPE,
                )
                activity.contentResolver.query(uri, projection, null, null, null)?.use { c ->
                    val sizeIdx = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
                    val typeIdx = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
                    val mimeIdx = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)
                    while (c.moveToNext()) {
                        val size = c.getLong(sizeIdx)
                        val type = c.getInt(typeIdx)
                        if (type == MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE) {
                            photos += size
                        } else if (type == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) {
                            videos += size
                        } else if (type == MediaStore.Files.FileColumns.MEDIA_TYPE_AUDIO) {
                            audio += size
                        } else if (isDocumentMime(c.getString(mimeIdx))) {
                            docs += size
                        }
                    }
                }
                val data = HashMap<String, Any>()
                data["total"] = total
                data["free"] = free
                data["photos"] = photos
                data["videos"] = videos
                data["audio"] = audio
                data["docs"] = docs
                mainHandler.post { result.success(data) }
            } catch (t: Throwable) {
                val message = t.message ?: t.javaClass.simpleName
                mainHandler.post { result.error("STORAGE_STATS_FAILED", message, null) }
            }
        }
    }

    private fun isDocumentMime(mime: String?): Boolean {
        if (mime == null) return false
        return mime == "application/pdf" ||
            mime == "application/msword" ||
            mime == "application/rtf" ||
            mime == "application/epub+zip" ||
            mime.startsWith("text/") ||
            mime.startsWith("application/vnd.ms-") ||
            mime.startsWith("application/vnd.openxmlformats-officedocument") ||
            mime.startsWith("application/vnd.oasis.opendocument")
    }

    // ----------------------------------------------------------------- delete

    private fun deleteFiles(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<List<*>>("paths")
        val paths = ArrayList<String>()
        if (raw != null) {
            for (item in raw) {
                if (item is String && item.isNotEmpty()) paths.add(item)
            }
        }
        if (paths.isEmpty()) {
            val empty = HashMap<String, Any>()
            empty["deleted"] = ArrayList<String>()
            empty["failed"] = ArrayList<String>()
            empty["cancelled"] = false
            result.success(empty)
            return
        }
        if (pendingDelete != null) {
            result.error("DELETE_BUSY", "Another delete is waiting for confirmation.", null)
            return
        }
        executor.execute {
            try {
                val deleted = ArrayList<String>()
                val stillThere = ArrayList<String>()
                for (p in paths) {
                    val ok = if (p.startsWith("content://")) deleteContentUri(p) else deletePlainFile(p)
                    if (ok) deleted.add(p) else stillThere.add(p)
                }
                if (stillThere.isNotEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val uris = resolveMediaUris(stillThere)
                    if (uris.isNotEmpty()) {
                        val confirmPaths = ArrayList<String>(uris.keys)
                        val failedNow = ArrayList<String>(stillThere)
                        failedNow.removeAll(confirmPaths.toSet())
                        val uriList = ArrayList<Uri>(uris.values)
                        mainHandler.post {
                            startDeleteRequest(result, uriList, deleted, confirmPaths, failedNow)
                        }
                        return@execute
                    }
                }
                val out = HashMap<String, Any>()
                out["deleted"] = deleted
                out["failed"] = stillThere
                out["cancelled"] = false
                mainHandler.post { result.success(out) }
            } catch (t: Throwable) {
                val message = t.message ?: t.javaClass.simpleName
                mainHandler.post { result.error("DELETE_FAILED", message, null) }
            }
        }
    }

    private fun startDeleteRequest(
        result: MethodChannel.Result,
        uris: List<Uri>,
        deleted: List<String>,
        confirmPaths: List<String>,
        failedNow: List<String>,
    ) {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                result.error("UNSUPPORTED", "This Android version cannot confirm deletes this way.", null)
                return
            }
            val pendingIntent = MediaStore.createDeleteRequest(activity.contentResolver, uris)
            pendingDelete = result
            pendingDeleted = deleted
            pendingConfirm = confirmPaths
            pendingFailed = failedNow
            activity.startIntentSenderForResult(pendingIntent.intentSender, REQUEST_DELETE, null, 0, 0, 0)
        } catch (t: Throwable) {
            pendingDelete = null
            result.error("DELETE_REQUEST_FAILED", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun deletePlainFile(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) return true
        if (isProtectedPath(file)) return false
        val ok = try {
            if (file.isDirectory) file.deleteRecursively() else file.delete()
        } catch (t: Throwable) {
            false
        }
        if (ok) forgetInMediaStore(path)
        return ok
    }

    private fun isProtectedPath(file: File): Boolean {
        return try {
            val canonical = file.canonicalFile
            val root = Environment.getExternalStorageDirectory().canonicalFile
            canonical == root || (canonical.parentFile == root && canonical.name == "Android")
        } catch (t: Throwable) {
            true
        }
    }

    private fun deleteContentUri(raw: String): Boolean {
        val uri = Uri.parse(raw)
        return try {
            if (DocumentsContract.isDocumentUri(activity, uri)) {
                DocumentsContract.deleteDocument(activity.contentResolver, uri)
            } else {
                activity.contentResolver.delete(uri, null, null) > 0
            }
        } catch (t: Throwable) {
            false
        }
    }

    private fun forgetInMediaStore(path: String) {
        try {
            activity.contentResolver.delete(
                MediaStore.Files.getContentUri("external"),
                "_data=?",
                arrayOf(path),
            )
        } catch (t: Throwable) {
            // best effort only
        }
        try {
            MediaScannerConnection.scanFile(activity, arrayOf(path), null, null)
        } catch (t: Throwable) {
            // best effort only
        }
    }

    private fun resolveMediaUris(paths: List<String>): Map<String, Uri> {
        val out = LinkedHashMap<String, Uri>()
        val filesUri = MediaStore.Files.getContentUri("external")
        for (chunk in paths.chunked(50)) {
            val placeholders = chunk.joinToString(",") { "?" }
            val cursor = activity.contentResolver.query(
                filesUri,
                arrayOf("_id", "_data"),
                "_data IN ($placeholders)",
                chunk.toTypedArray(),
                null,
            ) ?: continue
            cursor.use { c ->
                val idIdx = c.getColumnIndexOrThrow("_id")
                val dataIdx = c.getColumnIndexOrThrow("_data")
                while (c.moveToNext()) {
                    val data = c.getString(dataIdx)
                    if (data != null) {
                        out[data] = ContentUris.withAppendedId(filesUri, c.getLong(idIdx))
                    }
                }
            }
        }
        return out
    }

    // -------------------------------------------------------------- uninstall

    private fun uninstallApp(call: MethodCall, result: MethodChannel.Result) {
        val pkg = call.argument<String>("package")
        if (pkg.isNullOrEmpty()) {
            result.error("BAD_ARGS", "Missing package name.", null)
            return
        }
        if (pkg == activity.packageName) {
            result.error("SELF", "OmniDrop cannot uninstall itself from here.", null)
            return
        }
        val info = try {
            activity.packageManager.getApplicationInfo(pkg, 0)
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
        if (info == null) {
            result.error("NOT_INSTALLED", "That app is not installed.", null)
            return
        }
        val isSystem = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0 &&
            (info.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0
        if (isSystem) {
            result.error("SYSTEM_APP", "System apps cannot be uninstalled.", null)
            return
        }
        val intent = Intent(Intent.ACTION_DELETE, Uri.parse("package:" + pkg))
        activity.startActivity(intent)
        val out = HashMap<String, Any>()
        out["launched"] = true
        result.success(out)
    }

    // -------------------------------------------------------------------- APK

    private fun findApkFiles(result: MethodChannel.Result) {
        executor.execute {
            try {
                val filesUri = MediaStore.Files.getContentUri("external")
                val projection = arrayOf("_data", "_display_name", "_size", "date_modified")
                val selection = "mime_type = ? OR _display_name LIKE ?"
                val args = arrayOf("application/vnd.android.package-archive", "%.apk")
                val list = ArrayList<Map<String, Any>>()
                activity.contentResolver.query(filesUri, projection, selection, args, "date_modified DESC")?.use { c ->
                    val dataIdx = c.getColumnIndexOrThrow("_data")
                    val nameIdx = c.getColumnIndexOrThrow("_display_name")
                    val sizeIdx = c.getColumnIndexOrThrow("_size")
                    val modIdx = c.getColumnIndexOrThrow("date_modified")
                    while (c.moveToNext() && list.size < 500) {
                        val path = c.getString(dataIdx)
                        if (path == null || !File(path).exists()) continue
                        val entry = HashMap<String, Any>()
                        entry["path"] = path
                        entry["name"] = c.getString(nameIdx) ?: File(path).name
                        entry["size"] = c.getLong(sizeIdx)
                        entry["modified"] = c.getLong(modIdx)
                        list.add(entry)
                    }
                }
                mainHandler.post { result.success(list) }
            } catch (t: Throwable) {
                val message = t.message ?: t.javaClass.simpleName
                mainHandler.post { result.error("APK_SCAN_FAILED", message, null) }
            }
        }
    }

    private fun getApkInfo(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("BAD_ARGS", "Missing file path.", null)
            return
        }
        executor.execute {
            try {
                val pm = activity.packageManager
                val info = pm.getPackageArchiveInfo(path, 0)
                val appInfo = info?.applicationInfo
                if (info == null || appInfo == null) {
                    mainHandler.post { result.error("NOT_APK", "This is not a readable APK file.", null) }
                    return@execute
                }
                appInfo.sourceDir = path
                appInfo.publicSourceDir = path
                val label = pm.getApplicationLabel(appInfo).toString()
                val apkVersion = versionCodeOf(info)
                var state = "not_installed"
                try {
                    val installed = pm.getPackageInfo(info.packageName, 0)
                    state = if (versionCodeOf(installed) >= apkVersion) "installed" else "update"
                } catch (e: PackageManager.NameNotFoundException) {
                    // not installed
                }
                val iconBytes: ByteArray? = try {
                    iconToPng(pm.getApplicationIcon(appInfo))
                } catch (t: Throwable) {
                    null
                }
                val data = HashMap<String, Any?>()
                data["package"] = info.packageName
                data["label"] = label
                data["versionName"] = info.versionName
                data["versionCode"] = apkVersion
                data["state"] = state
                data["icon"] = iconBytes
                mainHandler.post { result.success(data) }
            } catch (t: Throwable) {
                val message = t.message ?: t.javaClass.simpleName
                mainHandler.post { result.error("APK_INFO_FAILED", message, null) }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun versionCodeOf(info: PackageInfo): Long {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            info.versionCode.toLong()
        }
    }

    private fun iconToPng(drawable: Drawable): ByteArray {
        val size = 96
        val bitmap: Bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            Bitmap.createScaledBitmap(drawable.bitmap, size, size, true)
        } else {
            val created = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(created)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            created
        }
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        return stream.toByteArray()
    }

    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("BAD_ARGS", "Missing file path.", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("NO_FILE", "The APK file no longer exists.", null)
            return
        }
        if (!activity.packageManager.canRequestPackageInstalls()) {
            result.error("INSTALL_NOT_ALLOWED", "Allow OmniDrop to install apps first.", null)
            return
        }
        val uri: Uri = try {
            FileProvider.getUriForFile(activity, activity.packageName + ".fileprovider", file)
        } catch (e: IllegalArgumentException) {
            result.error("FILE_NOT_SHAREABLE", e.message ?: "This file location is not shareable.", null)
            return
        }
        val intent = Intent(Intent.ACTION_VIEW)
        intent.setDataAndType(uri, "application/vnd.android.package-archive")
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(intent)
        val out = HashMap<String, Any>()
        out["launched"] = true
        result.success(out)
    }

    private fun openInstallSettings(result: MethodChannel.Result) {
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:" + activity.packageName),
        )
        activity.startActivity(intent)
        result.success(true)
    }
}

/** Makes sure a MethodChannel result is answered at most once. */
private class OnceResult(private val inner: MethodChannel.Result) : MethodChannel.Result {
    private var done = false

    override fun success(result: Any?) {
        if (done) return
        done = true
        inner.success(result)
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        if (done) return
        done = true
        inner.error(errorCode, errorMessage, errorDetails)
    }

    override fun notImplemented() {
        if (done) return
        done = true
        inner.notImplemented()
    }
}
