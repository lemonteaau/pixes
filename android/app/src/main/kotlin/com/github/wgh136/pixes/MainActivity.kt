package com.github.wgh136.pixes

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File

class MainActivity: FlutterActivity() {
    private val updatePrefs by lazy {
        getSharedPreferences("apk_update", MODE_PRIVATE)
    }
    private var waitingForInstallPermission = false
    private var returningFromInstaller = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        //获取http代理
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pixes/proxy"
        ).setMethodCallHandler { _, res ->
            res.success(getProxy())
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pixes/screen_awake"
        ).setMethodCallHandler { call, res ->
            if (call.method != "setKeepScreenOn") {
                res.notImplemented()
                return@setMethodCallHandler
            }
            val enabled = call.arguments as? Boolean ?: false
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            res.success(null)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pixes/apk_installer"
        ).setMethodCallHandler { call, result ->
            if (call.method != "installApk") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            if (path == null) {
                result.error("INVALID_APK", "APK path is missing", null)
                return@setMethodCallHandler
            }
            val apkFile = File(path)
            val updateDirectory = File(cacheDir, "apk_updates").canonicalFile
            if (!apkFile.canonicalPath.startsWith(updateDirectory.path + File.separator) ||
                !apkFile.isFile || !apkFile.name.endsWith(".apk", ignoreCase = true)
            ) {
                result.error("INVALID_APK", "APK path is invalid", null)
                return@setMethodCallHandler
            }

            // Remembered so the APK is deleted once the new version runs.
            updatePrefs.edit().putString("path", apkFile.absolutePath).apply()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                try {
                    waitingForInstallPermission = true
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                    result.success(null)
                } catch (e: Exception) {
                    waitingForInstallPermission = false
                    clearPendingApk(deleteFile = true)
                    result.error("INSTALL_PERMISSION", e.message, null)
                }
                return@setMethodCallHandler
            }

            try {
                launchApkInstaller(apkFile)
                result.success(null)
            } catch (e: Exception) {
                clearPendingApk(deleteFile = true)
                result.error("INSTALL_FAILED", e.message, null)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        when {
            waitingForInstallPermission -> {
                waitingForInstallPermission = false
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                    packageManager.canRequestPackageInstalls()
                ) {
                    val apkFile = updatePrefs.getString("path", null)?.let(::File)
                    if (apkFile != null && apkFile.isFile) {
                        try {
                            launchApkInstaller(apkFile)
                        } catch (e: Exception) {
                            clearPendingApk(deleteFile = true)
                            Toast.makeText(this, "无法打开 APK 安装程序", Toast.LENGTH_LONG).show()
                        }
                    } else {
                        clearPendingApk(deleteFile = true)
                    }
                } else {
                    clearPendingApk(deleteFile = true)
                    Toast.makeText(this, "允许 pixes 安装应用后才能更新", Toast.LENGTH_LONG).show()
                }
            }

            // Back from the installer without updating: drop the APK.
            returningFromInstaller -> {
                returningFromInstaller = false
                clearPendingApk(deleteFile = true)
            }

            else -> cleanupInstalledApk()
        }
    }

    private fun launchApkInstaller(apkFile: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.apkprovider", apkFile)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
        returningFromInstaller = true
    }

    /// After an update the app restarts, so any remembered APK is stale.
    private fun cleanupInstalledApk() {
        if (updatePrefs.getString("path", null) != null) {
            clearPendingApk(deleteFile = true)
        }
    }

    private fun clearPendingApk(deleteFile: Boolean) {
        if (deleteFile) {
            updatePrefs.getString("path", null)?.let { File(it).delete() }
        }
        updatePrefs.edit().clear().apply()
    }

    private fun getProxy(): String{
        val host = System.getProperty("http.proxyHost")
        val port = System.getProperty("http.proxyPort")
        return if(host!=null&&port!=null){
            "$host:$port"
        }else{
            "No Proxy"
        }
    }
}
