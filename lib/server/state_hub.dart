import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 播放器状态，字段与 Node 版 playerState / JSON 完全一致
class PlayerState {
  bool isPlaying = false;
  bool isFadingOut = false;
  String? currentFile;
  int elapsedSeconds = 0;
  int? targetDuration;
  int loopCount = 0;
  String audioDevice = 'default';
  int volume = 100;
  int systemVolume = 100;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'isPlaying': isPlaying,
        'isFadingOut': isFadingOut,
        'currentFile': currentFile,
        'elapsedSeconds': elapsedSeconds,
        'targetDuration': targetDuration,
        'loopCount': loopCount,
        'audioDevice': audioDevice,
        'volume': volume,
        'systemVolume': systemVolume,
      };
}

/// WebSocket 客户端管理与状态广播
/// （对应 Node 版 playerState.players 集合 + broadcastState）
class StateHub {
  StateHub(this.state);

  final PlayerState state;
  final Set<WebSocketChannel> _clients = <WebSocketChannel>{};

  void handleConnection(WebSocketChannel channel) {
    _clients.add(channel);
    _send(channel);
    // 前端只收不发业务消息；连接关闭/出错时移除
    channel.stream.listen(
      (_) {},
      onDone: () => _clients.remove(channel),
      onError: (Object e) {
        debugPrint('[WS] 连接异常断开: $e');
        _clients.remove(channel);
      },
      cancelOnError: true,
    );
  }

  void broadcast() {
    if (_clients.isEmpty) return;
    String message;
    try {
      message = jsonEncode(<String, dynamic>{
        'type': 'state_update',
        'data': state.toJson(),
      });
    } catch (e) {
      debugPrint('[WS] 状态序列化失败: $e');
      return;
    }
    for (final client in List.of(_clients)) {
      try {
        client.sink.add(message);
      } catch (e) {
        debugPrint('[WS] 推送失败，移除客户端: $e');
        _clients.remove(client);
      }
    }
  }

  void _send(WebSocketChannel channel) {
    try {
      channel.sink.add(jsonEncode(<String, dynamic>{
        'type': 'state_update',
        'data': state.toJson(),
      }));
    } catch (e) {
      debugPrint('[WS] 初始状态发送失败: $e');
    }
  }
}
