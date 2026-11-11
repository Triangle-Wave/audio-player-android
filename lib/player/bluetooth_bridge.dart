import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 蓝牙桥接：与 MainActivity.kt 的 MethodChannel("audio_player/native") 对应。
///
/// 应用无法程序化关闭蓝牙，
/// 因此「关闭蓝牙」统一实现为打开系统蓝牙设置页，
/// 由用户在系统界面完成关闭动作。
class BluetoothBridge {
  static const MethodChannel _channel = MethodChannel('audio_player/native');

  /// 打开系统蓝牙设置页；调用失败返回 false
  Future<bool> openPanel() async {
    try {
      final opened = await _channel.invokeMethod<bool>('openBluetoothPanel');
      return opened ?? false;
    } catch (e) {
      debugPrint('[蓝牙] 打开系统蓝牙设置页失败: $e');
      return false;
    }
  }

  /// 读取蓝牙开关状态；null 表示未知（无蓝牙适配器或未授予 BLUETOOTH_CONNECT）
  Future<bool?> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isBluetoothEnabled');
    } catch (e) {
      debugPrint('[蓝牙] 读取开关状态失败: $e');
      return null;
    }
  }

  /// 申请 BLUETOOTH_CONNECT 权限；Android 12 以下无需该权限，直接返回 true
  Future<bool> ensurePermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('ensureBluetoothPermission');
      return granted ?? false;
    } catch (e) {
      debugPrint('[蓝牙] 申请蓝牙权限失败: $e');
      return false;
    }
  }
}
