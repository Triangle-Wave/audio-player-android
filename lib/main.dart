import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 前台服务 + 媒体通知（锁屏后持续播放的关键）；失败仅降级为无前台服务
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.twave.audio_player.playback',
      androidNotificationChannelName: '音频播放',
      androidNotificationOngoing: true,
    );
  } catch (e, st) {
    debugPrint('[初始化] JustAudioBackground 初始化失败: $e\n$st');
  }

  runApp(const AudioPlayerApp());
}

class AudioPlayerApp extends StatelessWidget {
  const AudioPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.dark(
      primary: const Color(0xFF00D4FF),
      secondary: const Color(0xFF7B2FF7),
      surface: const Color(0xFF16213E),
    );
    return MaterialApp(
      title: '音频播放器',
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1A1A2E),
      ),
      home: const HomeScreen(),
    );
  }
}
