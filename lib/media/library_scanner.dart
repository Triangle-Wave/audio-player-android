import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AudioFileEntry {
  const AudioFileEntry({
    required this.name,
    required this.path,
    required this.rawSize,
    required this.modified,
  });

  final String name;
  final String path;
  final int rawSize;
  final DateTime modified;
}

/// 扫描音乐库目录（内置公共目录 + 用户添加的自定义目录），构建"文件名 -> 条目"索引。
/// 前端只传文件名（与 Node 版 uploads 目录行为一致），索引同时充当路径白名单。
class LibraryScanner {
  LibraryScanner();

  /// 应用专属外部目录可通过 adb push 免权限写入
  static const String appExternalDir =
      '/storage/emulated/0/Android/data/com.twave.audio_player/files';

  static final RegExp _audioExt = RegExp(
    r'\.(m4s|mp4|mp3|aac|wav|flac|m4a|webm|mkv|avi|mov|wma|ogg)$',
    caseSensitive: false,
  );

  /// 内置扫描根（始终生效）；用户添加的自定义目录存于 [customDirs]
  static const List<String> defaultRoots = <String>[
    '/storage/emulated/0/Music',
    '/storage/emulated/0/Download',
    appExternalDir,
  ];

  static const String _customDirsKey = 'library_dirs';

  /// 用户通过 UI 添加的自定义音乐库目录
  List<String> customDirs = <String>[];

  /// 本次扫描实际使用的全部根目录
  List<String> get roots => <String>[...defaultRoots, ...customDirs];

  /// 启动时恢复上次保存的自定义目录列表
  Future<void> loadCustomDirs(SharedPreferences prefs) async {
    final saved = prefs.getStringList(_customDirsKey);
    customDirs = (saved ?? const <String>[])
        .map(normalizeDir)
        .whereType<String>()
        .toList();
  }

  /// 校验并添加自定义库目录（规范化、去重）；持久化失败时回滚并返回 false
  Future<bool> addCustomDir(SharedPreferences prefs, String rawPath) async {
    final path = normalizeDir(rawPath);
    if (path == null ||
        defaultRoots.contains(path) ||
        customDirs.contains(path)) {
      return false;
    }
    customDirs.add(path);
    if (!await _persistCustomDirs(prefs)) {
      customDirs.remove(path);
      return false;
    }
    return true;
  }

  /// 移除自定义库目录；持久化失败时回滚并返回 false
  Future<bool> removeCustomDir(SharedPreferences prefs, String path) async {
    if (!customDirs.remove(path)) return false;
    if (!await _persistCustomDirs(prefs)) {
      customDirs.add(path);
      return false;
    }
    return true;
  }

  Future<bool> _persistCustomDirs(SharedPreferences prefs) async {
    try {
      return await prefs.setStringList(_customDirsKey, customDirs);
    } catch (e) {
      debugPrint('[曲库] 目录列表保存失败: $e');
      return false;
    }
  }

  /// 规范化目录路径：非绝对路径返回 null；去除首尾空白与多余结尾斜杠
  static String? normalizeDir(String raw) {
    var p = raw.trim();
    if (p.isEmpty || !p.startsWith('/')) return null;
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  List<AudioFileEntry> entries = <AudioFileEntry>[];
  String? lastError;
  DateTime? lastScanTime;

  final Map<String, AudioFileEntry> _byName = <String, AudioFileEntry>{};

  AudioFileEntry? find(String name) => _byName[name];

  Future<void> scan() async {
    final found = <String, AudioFileEntry>{};
    final errors = <String>[];

    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      try {
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (!_audioExt.hasMatch(name)) continue;
          if (found.containsKey(name)) continue;
          try {
            final stat = await entity.stat();
            found[name] = AudioFileEntry(
              name: name,
              path: entity.path,
              rawSize: stat.size,
              modified: stat.modified,
            );
          } catch (e) {
            // 单个文件 stat 失败不影响整体扫描
            debugPrint('[扫描] 读取文件信息失败 $entity: $e');
          }
        }
      } catch (e) {
        // 整个目录不可读（权限不足等）：记录并降级为跳过该目录
        debugPrint('[扫描] 目录不可读 $root: $e');
        errors.add('$root: $e');
      }
    }

    entries = found.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _byName
      ..clear()
      ..addAll(found);
    lastError = errors.isEmpty ? null : errors.join('; ');
    lastScanTime = DateTime.now();
    debugPrint('[扫描] 完成，共 ${entries.length} 个音频文件'
        '${lastError == null ? '' : '（部分目录失败）'}');
  }

  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 对应 Node 版 stat.mtime.toLocaleString('zh-CN')
  static String formatDateTimeZh(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}/${t.month}/${t.day} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
