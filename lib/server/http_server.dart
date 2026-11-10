import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../media/library_scanner.dart';
import '../player/playback_service.dart';
import '../player/system_volume_bridge.dart';
import 'state_hub.dart';

/// 内嵌控制服务器：路由与响应格式与 Node 版逐条对应
class ControlServer {
  ControlServer({
    required this.state,
    required this.hub,
    required this.scanner,
    required this.playback,
    required this.systemVolume,
    required this.saveVolume,
  });

  final PlayerState state;
  final StateHub hub;
  final LibraryScanner scanner;
  final PlaybackService playback;
  final SystemVolumeBridge systemVolume;
  final Future<void> Function(int volume) saveVolume;

  HttpServer? _bound;
  Uint8List? _controlPage;

  bool get isRunning => _bound != null;

  Future<void> start({int port = 31901}) async {
    if (isRunning) return;
    _controlPage =
        (await rootBundle.load('assets/web/control.html')).buffer.asUint8List();

    final router = Router()
      ..get('/control', _serveControlPage)
      ..get('/control.html', _serveControlPage)
      ..get('/api/state', _guard(_apiState))
      ..get('/api/files', _guard(_apiFiles))
      ..get('/api/devices', _guard(_apiDevices))
      ..get('/api/system-volume', _guard(_apiGetSystemVolume))
      ..post('/api/play', _guard(_apiPlay))
      ..post('/api/stop', _guard(_apiStop))
      ..post('/api/volume', _guard(_apiSetVolume))
      ..post('/api/system-volume', _guard(_apiSetSystemVolume))
      ..mount('/uploads/', _guard(_serveUploads));

    // WebSocket 升级请求走根路径（前端 new WebSocket(ws://host/)），
    // 普通请求先经 Router，未命中再落到 wsHandler。
    final wsHandler = webSocketHandler(hub.handleConnection);
    final handler = Cascade()
        .add(router.call)
        .add(wsHandler)
        .handler;

    _bound = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    debugPrint('[服务] 控制服务器已启动，端口 $port');
  }

  Future<void> stop() async {
    final server = _bound;
    _bound = null;
    if (server == null) return;
    try {
      await server.close(force: true);
    } catch (e) {
      debugPrint('[服务] 关闭失败: $e');
    }
  }

  // ---------- 基础设施 ----------

  /// 统一异常兜底：任何处理器抛错都转为 500 JSON 并记录日志
  Handler _guard(Future<Response> Function(Request) inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } catch (e, st) {
        debugPrint('[HTTP] ${request.method} ${request.url} 处理异常: $e\n$st');
        return _json(<String, dynamic>{'error': '内部错误: $e'}, 500);
      }
    };
  }

  Response _json(Map<String, dynamic> data, [int status = 200]) =>
      Response(status, body: jsonEncode(data),
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          });

  Future<Map<String, dynamic>?> _readJsonBody(Request request) async {
    try {
      final body = await request.readAsString();
      if (body.trim().isEmpty) return null;
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      debugPrint('[HTTP] 请求体解析失败: $e');
      return null;
    }
  }

  int? _readIntArg(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  // ---------- 页面与静态资源 ----------

  Response _serveControlPage(Request request) {
    final bytes = _controlPage;
    if (bytes == null) {
      return Response.internalServerError(body: 'control page not loaded');
    }
    return Response.ok(bytes, headers: <String, String>{
      'content-type': 'text/html; charset=utf-8',
    });
  }

  Future<Response> _serveUploads(Request request) async {
    final name = Uri.decodeComponent(request.url.path);
    if (name.isEmpty || name.contains('/') || name.contains('\\')) {
      return _json(<String, dynamic>{'error': '非法文件路径'}, 400);
    }
    var entry = scanner.find(name);
    if (entry == null) {
      await scanner.scan();
      entry = scanner.find(name);
    }
    if (entry == null) {
      return _json(<String, dynamic>{'error': '文件不存在'}, 404);
    }
    return Response.ok(
      File(entry.path).openRead(),
      headers: <String, String>{
        'content-type': _contentTypeFor(name),
      },
    );
  }

  String _contentTypeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.m4s')) return 'audio/mp4';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.aac')) return 'audio/aac';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.webm')) return 'audio/webm';
    return 'application/octet-stream';
  }

  // ---------- API（与 Node 版一一对应） ----------

  Future<Response> _apiState(Request request) async => _json(state.toJson());

  Future<Response> _apiFiles(Request request) async {
    if (scanner.lastScanTime == null || scanner.entries.isEmpty) {
      await scanner.scan();
    }
    return _json(<String, dynamic>{
      'files': scanner.entries
          .map((e) => <String, dynamic>{
                'name': e.name,
                'size': LibraryScanner.formatFileSize(e.rawSize),
                'rawSize': e.rawSize,
                'modified': LibraryScanner.formatDateTimeZh(e.modified),
              })
          .toList(),
    });
  }

  Future<Response> _apiDevices(Request request) async {
    // Android 无法像 Windows 那样枚举/切换输出设备，固定返回默认设备保证前端兼容
    return _json(<String, dynamic>{
      'devices': <Map<String, String>>[
        <String, String>{'name': '默认音频设备', 'id': 'default'},
      ],
    });
  }

  Future<Response> _apiGetSystemVolume(Request request) async {
    final vol = await systemVolume.getVolume();
    if (vol >= 0) state.systemVolume = vol;
    return _json(<String, dynamic>{'systemVolume': state.systemVolume});
  }

  Future<Response> _apiPlay(Request request) async {
    final body = await _readJsonBody(request);
    if (body == null) return _json(<String, dynamic>{'error': '无效的请求体'}, 400);

    final file = body['file'];
    if (file is! String || file.isEmpty) {
      return _json(<String, dynamic>{'error': '未指定文件'}, 400);
    }

    var entry = scanner.find(file);
    if (entry == null) {
      await scanner.scan();
      entry = scanner.find(file);
    }
    if (entry == null) {
      return _json(<String, dynamic>{'error': '文件不存在'}, 404);
    }

    final volumeArg = _readIntArg(body, 'volume');
    if (volumeArg != null) {
      state.volume = volumeArg.clamp(0, 100).toInt();
      await saveVolume(state.volume);
    }

    final device = body['audioDevice'];
    state.audioDevice = device is String && device.isNotEmpty ? device : 'default';

    final targetDuration = _readIntArg(body, 'targetDuration');

    unawaited(playback.start(entry.path, entry.name, targetDuration));

    return _json(<String, dynamic>{'success': true, 'message': '开始播放'});
  }

  Future<Response> _apiStop(Request request) async {
    playback.triggerStop();
    return _json(<String, dynamic>{'success': true, 'message': '正在淡出停止'});
  }

  Future<Response> _apiSetVolume(Request request) async {
    final body = await _readJsonBody(request);
    final volume = body == null ? null : _readIntArg(body, 'volume');
    if (volume == null) {
      return _json(<String, dynamic>{'error': '未指定音量'}, 400);
    }
    state.volume = volume.clamp(0, 100).toInt();
    try {
      await saveVolume(state.volume);
    } catch (e) {
      debugPrint('[音量] 持久化失败: $e');
    }
    hub.broadcast();
    return _json(<String, dynamic>{'success': true, 'volume': state.volume});
  }

  Future<Response> _apiSetSystemVolume(Request request) async {
    final body = await _readJsonBody(request);
    final volume = body == null ? null : _readIntArg(body, 'volume');
    if (volume == null) {
      return _json(<String, dynamic>{'error': '未指定音量'}, 400);
    }
    final clamped = volume.clamp(0, 100).toInt();
    final ok = await systemVolume.setVolume(clamped);
    if (!ok) {
      return _json(<String, dynamic>{'error': '设置系统音量失败'}, 500);
    }
    state.systemVolume = clamped;
    hub.broadcast();
    return _json(<String, dynamic>{'success': true, 'systemVolume': clamped});
  }
}
