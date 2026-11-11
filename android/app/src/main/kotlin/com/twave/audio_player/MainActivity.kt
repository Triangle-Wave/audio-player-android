package com.twave.audio_player

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val channelName = "audio_player/native"
    private val permRequestCode = 31901
    private val manageStorageRequestCode = 31902
    private val pickDirRequestCode = 31903
    private val bluetoothPermRequestCode = 31904
    private var pendingPermResult: MethodChannel.Result? = null
    private var pendingManageResult: MethodChannel.Result? = null
    private var pendingPickDirResult: MethodChannel.Result? = null
    private var pendingBluetoothPermResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getSystemVolume" -> result.success(currentSystemVolume())
                        "setSystemVolume" -> {
                            val volume = call.argument<Int>("volume")
                            if (volume == null || volume < 0 || volume > 100) {
                                result.error("INVALID_ARGUMENT", "volume must be int 0-100", null)
                            } else {
                                applySystemVolume(volume)
                                result.success(volume)
                            }
                        }
                        "ensureStoragePermission" -> ensureStoragePermission(result)
                        "ensureManageStorage" -> ensureManageStorage(result)
                        "pickDirectory" -> pickDirectory(result)
                        "openBluetoothPanel" -> openBluetoothPanel(result)
                        "isBluetoothEnabled" -> result.success(currentBluetoothEnabled())
                        "ensureBluetoothPermission" -> ensureBluetoothPermission(result)
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("NATIVE_ERROR", e.message, null)
                }
            }
    }

    private fun audioManager(): AudioManager =
        getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun currentSystemVolume(): Int {
        val am = audioManager()
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return -1
        return am.getStreamVolume(AudioManager.STREAM_MUSIC) * 100 / max
    }

    private fun applySystemVolume(volume: Int) {
        val am = audioManager()
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return
        val target = ((volume * max) + 50) / 100
        am.setStreamVolume(AudioManager.STREAM_MUSIC, target.coerceIn(0, max), 0)
    }

    private fun requiredAudioPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
            arrayOf(Manifest.permission.READ_MEDIA_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
        else
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)

    private fun hasStoragePermission(): Boolean =
        requiredAudioPermissions().all {
            checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }

    private fun ensureStoragePermission(result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            result.success(true)
            return
        }
        pendingPermResult?.success(false)
        pendingPermResult = result
        // 授权弹窗期间 Dart 侧等待；结果经 onRequestPermissionsResult 回传（Dart 侧带超时兜底）
        requestPermissions(requiredAudioPermissions(), permRequestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            permRequestCode -> {
                val result = pendingPermResult
                pendingPermResult = null
                if (result == null) return
                val granted = grantResults.isNotEmpty() &&
                    grantResults.all { it == PackageManager.PERMISSION_GRANTED }
                result.success(granted)
            }
            bluetoothPermRequestCode -> {
                val result = pendingBluetoothPermResult
                pendingBluetoothPermResult = null
                if (result == null) return
                val granted = grantResults.isNotEmpty() &&
                    grantResults.all { it == PackageManager.PERMISSION_GRANTED }
                result.success(granted)
            }
        }
    }

    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()

    // 申请"所有文件访问"权限：未授权则跳系统设置页，用户返回后经 onActivityResult 回传
    private fun ensureManageStorage(result: MethodChannel.Result) {
        if (hasAllFilesAccess()) {
            result.success(true)
            return
        }
        pendingManageResult?.success(false)
        pendingManageResult = result
        val appPage = Intent(
            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
            Uri.parse("package:$packageName")
        )
        try {
            startActivityForResult(appPage, manageStorageRequestCode)
        } catch (e: Exception) {
            // 部分 ROM 不支持直达应用页，降级到总开关设置页
            debugFallback(e)
            startActivityForResult(
                Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
                manageStorageRequestCode
            )
        }
    }

    private fun debugFallback(e: Exception) {
        io.flutter.Log.e("MainActivity", "直达所有文件访问设置页失败，改用总开关页", e)
    }

    // ---------- 蓝牙 ----------

    // 打开系统蓝牙设置页，由用户在系统界面关闭蓝牙
    private fun openBluetoothPanel(result: MethodChannel.Result) {
        val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            io.flutter.Log.e("MainActivity", "打开蓝牙设置页失败", e)
            result.success(false)
        }
    }

    // 读取蓝牙开关；无适配器或未授予 BLUETOOTH_CONNECT 时返回 null（未知）
    private fun currentBluetoothEnabled(): Boolean? {
        return try {
            val manager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val adapter = manager?.adapter ?: return null
            adapter.isEnabled
        } catch (e: SecurityException) {
            io.flutter.Log.w("MainActivity", "读取蓝牙状态缺少权限: ${e.message}")
            null
        } catch (e: Exception) {
            io.flutter.Log.e("MainActivity", "读取蓝牙状态失败", e)
            null
        }
    }

    // 申请 BLUETOOTH_CONNECT（Android 12+）；低版本无需该权限，直接回 true
    private fun ensureBluetoothPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(true)
            return
        }
        if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingBluetoothPermResult?.success(false)
        pendingBluetoothPermResult = result
        try {
            requestPermissions(
                arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
                bluetoothPermRequestCode
            )
        } catch (e: Exception) {
            pendingBluetoothPermResult = null
            io.flutter.Log.e("MainActivity", "申请蓝牙权限失败", e)
            result.success(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            manageStorageRequestCode -> {
                val result = pendingManageResult
                pendingManageResult = null
                result?.success(hasAllFilesAccess())
            }
            pickDirRequestCode -> {
                val result = pendingPickDirResult
                pendingPickDirResult = null
                val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
                if (uri == null) {
                    // 用户取消
                    result?.success(null)
                } else {
                    val path = treeUriToPhysicalPath(uri)
                    if (path == null) {
                        result?.error("UNRESOLVED_PATH", "所选位置无法映射为本机存储目录", null)
                    } else {
                        result?.success(path)
                    }
                }
            }
        }
    }

    // 打开系统文件管理器的目录选择器；用户选定后回传真实路径，取消回传 null
    private fun pickDirectory(result: MethodChannel.Result) {
        pendingPickDirResult?.success(null)
        pendingPickDirResult = result
        try {
            startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                pickDirRequestCode
            )
        } catch (e: Exception) {
            pendingPickDirResult = null
            result.error("NATIVE_ERROR", "无法打开文件选择器: ${e.message}", null)
        }
    }

    // 将 SAF 目录树 URI 解析为设备真实路径（primary:Music/xx → /storage/emulated/0/Music/xx）；
    // 主存储直接映射，其余存储卷经 StorageManager 尽力匹配，解析失败返回 null
    private fun treeUriToPhysicalPath(uri: Uri): String? {
        val docId = try {
            DocumentsContract.getTreeDocumentId(uri)
        } catch (e: Exception) {
            return null
        }
        val parts = docId.split(':', limit = 2)
        if (parts.size != 2) return null
        val volume = parts[0]
        val relative = parts[1]
        val root = if (volume == "primary") {
            Environment.getExternalStorageDirectory().absolutePath
        } else {
            // storageVolumes/state/directory 均要求 API 24~30 不等，低版本设备不支持
            // 非 primary 卷映射，直接降级返回 null（避免 NoSuchMethodError 崩溃）
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
            val sm = getSystemService(Context.STORAGE_SERVICE) as StorageManager
            var found: String? = null
            for (vol in sm.storageVolumes) {
                if (!vol.state.equals(Environment.MEDIA_MOUNTED, ignoreCase = true)) continue
                val dir = vol.directory ?: continue
                if (vol.uuid == volume || dir.absolutePath.endsWith("/$volume")) {
                    found = dir.absolutePath
                    break
                }
            }
            found ?: return null
        }
        return if (relative.isEmpty()) root else "$root/$relative"
    }
}
