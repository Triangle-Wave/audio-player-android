import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:just_audio_background/just_audio_background.dart';

import '../server/state_hub.dart' show PlayerState;

/// 淡出时长（秒），与 Node 版 FADE_DURATION 一致
const int kFadeDurationSeconds = 10;

/// 播放引擎：循环播放直到目标时长，最后 10 秒线性淡出；手动停止同样走淡出。
/// 控制循环为 100ms 轮询（对应 Node 版内嵌 PowerShell 的轮询循环）。
class PlaybackService {
  PlaybackService({
    required this.state,
    required this.onBroadcast,
    required this.onPlaybackEnded,
  });

  final PlayerState state;
  final void Function() onBroadcast;

  /// 播放结束通知：reason 为 'timer' 表示定时时长到达（手动停止、
  /// 自然播完、被新播放打断均不回调）
  final void Function(String reason) onPlaybackEnded;

  AudioPlayer? _player;
  Timer? _ticker;
  DateTime? _startTime;
  bool _stopRequested = false;
  Completer<void>? _playbackDone;

  /// 播放任务序号：新任务开始时自增，旧任务据此判断自己已被取代
  int _runSeq = 0;

  bool get isActive => state.isPlaying || state.isFadingOut;

  double get _elapsedSeconds => _startTime == null
      ? 0
      : DateTime.now().difference(_startTime!).inMilliseconds / 1000.0;

  /// 开始播放。若已有任务在播，先触发淡出并等待其结束（与 Node 版 startPlayback 一致）。
  Future<void> start(String filePath, String fileName, int? targetDuration) async {
    if (isActive) {
      debugPrint('[播放] 已有播放任务，先停止');
      triggerStop();
      try {
        await _playbackDone?.future.timeout(const Duration(seconds: 16));
      } on TimeoutException {
        debugPrint('[播放] 等待旧任务退出超时，继续新任务');
      } catch (e) {
        debugPrint('[播放] 等待旧任务结束异常: $e');
      }
    }

    _stopRequested = false;
    state
      ..currentFile = fileName
      ..loopCount = 0
      ..isPlaying = true
      ..isFadingOut = false
      ..elapsedSeconds = 0
      ..targetDuration =
          (targetDuration == null || targetDuration <= 0) ? null : targetDuration;
    onBroadcast();

    // 每秒刷新已播时长并广播（对应 setInterval）
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startTime != null && state.isPlaying) {
        state.elapsedSeconds = DateTime.now().difference(_startTime!).inSeconds;
        onBroadcast();
      }
    });

    _playbackDone = Completer<void>();
    final runSeq = ++_runSeq;
    unawaited(
      _run(filePath, fileName, runSeq).whenComplete(() async {
        await _cleanup();
        final done = _playbackDone;
        if (done != null && !done.isCompleted) done.complete();
      }),
    );
  }

  /// 触发停止：进入淡出流程，由控制循环执行渐弱（重复调用忽略）
  void triggerStop() {
    if (state.isFadingOut) {
      debugPrint('[播放] 已在淡出中，忽略重复停止');
      return;
    }
    if (_player == null && !state.isPlaying) {
      unawaited(_cleanup());
      return;
    }
    debugPrint('[播放] 触发停止（淡出）');
    _stopRequested = true;
    state.isFadingOut = true;
    onBroadcast();
    // 超过淡出时长的强制兜底在控制循环内执行（对应 forceKillTimer）
  }

  Future<void> _run(String filePath, String fileName, int runSeq) async {
    AudioPlayer? player;
    try {
      player = AudioPlayer();
      _player = player;

      // just_audio_background 要求 AudioSource 带 MediaItem 标签
      await player
          .setAudioSource(AudioSource.file(
            filePath,
            tag: MediaItem(
              id: filePath,
              album: '音频播放器',
              title: fileName,
            ),
          ))
          .timeout(const Duration(seconds: 20));

      final durationSec = (player.duration?.inMilliseconds ?? 0) / 1000.0;
      debugPrint('[播放] 开始播放: $fileName，时长 ${durationSec.toStringAsFixed(1)} 秒，'
          '目标时长 ${state.targetDuration ?? '不限'}');

      // 与原 PowerShell 版一致：元数据加载完成后才开始计时
      _startTime = DateTime.now();

      var loopCount = 0;
      var shouldStop = false;
      var fading = false;
      var fadeStartSec = 0.0;
      var fadeDurationSec = kFadeDurationSeconds.toDouble();

      while (!shouldStop) {
        if (state.targetDuration != null && _elapsedSeconds >= state.targetDuration!) {
          break;
        }

        // 循环重播：seek 回起点再播（play() 的 Future 会等播完，不能 await）
        await player.seek(Duration.zero);
        unawaited(player.play());
        loopCount++;
        state.loopCount = loopCount;
        onBroadcast();

        // ---- 内层轮询：每 100ms ----
        while (true) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final t = _elapsedSeconds;
          final target = state.targetDuration;

          if (target != null && t >= target) break;

          // 手动停止信号 -> 进入淡出
          if (_stopRequested && !fading) {
            fading = true;
            fadeStartSec = t;
            fadeDurationSec = kFadeDurationSeconds.toDouble();
          }

          // 自然结束前 10 秒 -> 提前进入淡出
          if (!fading && target != null && target - t <= kFadeDurationSeconds) {
            fading = true;
            if (target <= kFadeDurationSeconds) {
              fadeStartSec = 0;
              fadeDurationSec = target.toDouble();
            } else {
              fadeStartSec = (target - kFadeDurationSeconds).toDouble();
              fadeDurationSec = kFadeDurationSeconds.toDouble();
            }
          }

          // 应用音量（淡出期间乘衰减系数）；实时跟随音量调节
          final baseVolume = state.volume / 100.0;
          if (fading) {
            final fadeElapsed = t - fadeStartSec;
            if (fadeElapsed >= fadeDurationSec) {
              shouldStop = true;
              break;
            }
            final factor =
                (1.0 - fadeElapsed / fadeDurationSec).clamp(0.0, 1.0).toDouble();
            await player.setVolume(baseVolume * factor);

            // 手动淡出超时兜底（对应 forceKillTimer 15s）
            if (_stopRequested && fadeElapsed > 15) {
              debugPrint('[播放] 淡出超时，强制终止');
              shouldStop = true;
              break;
            }
          } else if ((player.volume - baseVolume).abs() > 0.001) {
            await player.setVolume(baseVolume);
          }

          // 自然播完检测 -> 外层循环决定重播或结束
          final pos = player.position.inMilliseconds / 1000.0;
          final completed = player.processingState == ProcessingState.completed;
          if (completed || (durationSec > 0 && pos >= durationSec - 0.3)) {
            break;
          }
        }

        try {
          await player.pause();
        } catch (e) {
          debugPrint('[播放] 暂停失败: $e');
        }

        if (shouldStop) break;
        // 未设置目标时长：只完整播一遍（与 Node 版一致）
        if (state.targetDuration == null) break;
      }

      try {
        await player.stop();
      } catch (e) {
        debugPrint('[播放] 停止失败: $e');
      }
      debugPrint('[播放] 结束：已播 ${_elapsedSeconds.toStringAsFixed(1)} 秒，'
          '循环 $loopCount 次');

      // 定时结束判定：目标时长已到达、非手动停止（含强制兜底）、
      // 且本轮任务未被新播放取代（runSeq 已被刷新）。
      // 提前淡出使 shouldStop 置位的定时结束同样满足该条件。
      var timerNotified = false;
      final targetSec = state.targetDuration;
      final timerReached = targetSec != null &&
          _elapsedSeconds >= targetSec &&
          !_stopRequested &&
          runSeq == _runSeq;
      if (timerReached && !timerNotified) {
        timerNotified = true;
        try {
          onPlaybackEnded('timer');
        } catch (e, st) {
          debugPrint('[播放] 结束通知回调异常: $e\n$st');
        }
      }
    } catch (e, st) {
      debugPrint('[播放] 播放异常: $e\n$st');
    } finally {
      if (player != null) {
        try {
          await player.dispose();
        } catch (e) {
          debugPrint('[播放] 播放器释放失败: $e');
        }
      }
      if (identical(_player, player)) _player = null;
    }
  }

  Future<void> _cleanup() async {
    _ticker?.cancel();
    _ticker = null;
    _startTime = null;
    _stopRequested = false;
    state
      ..isPlaying = false
      ..isFadingOut = false
      ..targetDuration = null;
    onBroadcast();
    debugPrint('[播放] 清理播放状态完成');
  }
}
