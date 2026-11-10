import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 与 MainActivity.kt 的 MethodChannel("audio_player/native") 对应
class SystemVolumeBridge {
  static const MethodChannel _channel = MethodChannel('audio_player/native');

  /// 返回 0-100；失败返回 -1（与 Node 版 getSystemVolume 失败语义一致）
  Future<int> getVolume() async {
    try {
      final v = await _channel.invokeMethod<int>('getSystemVolume');
      return v ?? -1;
    } catch (e) {
      debugPrint('[系统音量] 获取失败: $e');
      return -1;
    }
  }

  Future<bool> setVolume(int volume) async {
    final clamped = volume.clamp(0, 100);
    try {
      await _channel.invokeMethod<void>('setSystemVolume',
          <String, dynamic>{'volume': clamped});
      return true;
    } catch (e) {
      debugPrint('[系统音量] 设置失败 volume=$clamped: $e');
      return false;
    }
  }

  /// 申请媒体读取/通知权限；用户处理弹窗后返回是否全部授权。
  Future<bool> ensureStoragePermission(
      {Duration timeout = const Duration(seconds: 45)}) async {
    try {
      final granted = await _channel
          .invokeMethod<bool>('ensureStoragePermission')
          .timeout(timeout);
      return granted ?? false;
    } on TimeoutException {
      debugPrint('[权限] 授权弹窗超时未返回');
      return false;
    } catch (e) {
      debugPrint('[权限] 申请失败: $e');
      return false;
    }
  }

  /// 申请"所有文件访问"权限（扫描任意自定义目录必需）。
  /// 未授权时跳转系统设置页，用户开启并返回后回传结果；
  /// Android 10 及以下无需此权限，直接返回 true。
  Future<bool> ensureManageStorage(
      {Duration timeout = const Duration(minutes: 3)}) async {
    try {
      final granted = await _channel
          .invokeMethod<bool>('ensureManageStorage')
          .timeout(timeout);
      return granted ?? false;
    } on TimeoutException {
      debugPrint('[权限] 所有文件访问授权超时未返回');
      return false;
    } catch (e) {
      debugPrint('[权限] 所有文件访问申请失败: $e');
      return false;
    }
  }

  /// 打开系统文件管理器选择目录；返回所选目录的真实绝对路径，
  /// 用户取消时返回 null；所选位置无法映射为本机路径时抛出
  /// PlatformException(code: UNRESOLVED_PATH)。
  Future<String?> pickDirectory(
      {Duration timeout = const Duration(minutes: 5)}) async {
    try {
      final path =
          await _channel.invokeMethod<String>('pickDirectory').timeout(timeout);
      final trimmed = path?.trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    } on TimeoutException {
      debugPrint('[目录选择] 选择超时未返回');
      return null;
    } on PlatformException catch (e) {
      if (e.code == 'UNRESOLVED_PATH') rethrow;
      debugPrint('[目录选择] 调起选择器失败: $e');
      return null;
    } catch (e) {
      debugPrint('[目录选择] 调起选择器失败: $e');
      return null;
    }
  }
}
