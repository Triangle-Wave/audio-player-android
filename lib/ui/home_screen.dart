import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../media/library_scanner.dart';
import '../player/bluetooth_bridge.dart';
import '../player/playback_service.dart';
import '../player/system_volume_bridge.dart';
import '../server/http_server.dart';
import '../server/state_hub.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _port = 31901;
  static const String _volumeKey = 'player_volume';
  static const String _bluetoothPromptKey = 'bluetooth_prompt_after_play';

  final LibraryScanner _scanner = LibraryScanner();
  final PlayerState _playerState = PlayerState();
  final BluetoothBridge _bluetoothBridge = BluetoothBridge();

  SystemVolumeBridge? _bridge;
  StateHub? _hub;
  PlaybackService? _playback;
  ControlServer? _server;
  Timer? _uiTimer;

  bool _booting = true;
  bool _scanning = false;
  String? _bootError;
  bool _permissionGranted = true;
  List<String> _addresses = <String>[];
  SharedPreferences? _prefs;

  /// 定时播放设定：off=不限 / duration=按时长 / endtime=播到指定时刻
  String _timerMode = 'off';
  int _timerDurationMin = 30;
  TimeOfDay? _timerEndTime;

  /// 当前生效的播放目标时长（秒）；null = 不限。由 _applyTimerSetting 计算
  int? _targetSeconds;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    unawaited(_server?.stop());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      final bridge = SystemVolumeBridge();

      _playerState.volume = prefs.getInt(_volumeKey) ?? 100;
      _playerState.bluetoothPromptAfterPlay =
          prefs.getBool(_bluetoothPromptKey) ?? false;

      // 媒体读取权限；被拒不阻断启动，仅提示（应用专属目录仍可用）
      _permissionGranted = await bridge.ensureStoragePermission();

      await _scanner.loadCustomDirs(prefs);
      await _restoreTimerSettings();
      _targetSeconds = null;
      await _scanner.scan();

      final hub = StateHub(_playerState);
      final playback = PlaybackService(
        state: _playerState,
        onBroadcast: hub.broadcast,
        onPlaybackEnded: _handlePlaybackEnded,
      );
      final server = ControlServer(
        state: _playerState,
        hub: hub,
        scanner: _scanner,
        playback: playback,
        systemVolume: bridge,
        saveVolume: (int v) => prefs.setInt(_volumeKey, v),
        saveBluetoothPrompt: (bool v) => prefs.setBool(_bluetoothPromptKey, v),
        bluetooth: _bluetoothBridge,
      );

      await server.start(port: _port);

      final sysVol = await bridge.getVolume();
      if (sysVol >= 0) _playerState.systemVolume = sysVol;

      if (!mounted) return;
      setState(() {
        _bridge = bridge;
        _hub = hub;
        _playback = playback;
        _server = server;
        _addresses = const [];
      });
      await _refreshAddresses();

      // 界面每秒跟随播放状态刷新
      _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } catch (e, st) {
      debugPrint('[启动] 初始化失败: $e\n$st');
      if (mounted) {
        setState(() => _bootError = e.toString());
      }
    } finally {
      if (mounted) setState(() => _booting = false);
    }
  }

  Future<void> _refreshAddresses() async {
    final urls = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          urls.add('http://${addr.address}:$_port/control');
        }
      }
    } catch (e) {
      debugPrint('[网络] 获取本机地址失败: $e');
    }
    if (mounted) setState(() => _addresses = urls);
  }

  Future<void> _rescanFiles() async {
    if (_scanning || !mounted) return;
    setState(() => _scanning = true);
    try {
      await _scanner.scan();
    } catch (e) {
      debugPrint('[扫描] 手动刷新失败: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _retryPermission() async {
    final granted =
        await _bridge?.ensureStoragePermission() ?? false;
    await _rescanFiles();
    if (mounted) setState(() => _permissionGranted = granted);
  }

  String _dirLabel(String dir) {
    final parts = dir.split('/').where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? dir : parts.last;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(message), duration: const Duration(seconds: 2)));
  }

  Future<void> _showAddLibraryDialog() async {
    // 未授予"所有文件访问"时先引导授权（已授权则该方法立即返回）
    final allowed = await _bridge?.ensureManageStorage() ?? false;
    if (!allowed) {
      _toast('未授予「所有文件访问」权限，无法扫描所选目录');
      return;
    }
    final prefs = _prefs;
    if (prefs == null) {
      _toast('服务尚未就绪，请稍后再试');
      return;
    }

    // 调起系统文件管理器选择目录，返回真实绝对路径；取消时为 null
    String? path;
    try {
      path = await _bridge?.pickDirectory();
    } on PlatformException {
      _toast('所选位置不受支持，请选择本机存储中的文件夹');
      return;
    }
    if (!mounted || path == null) return;
    path = LibraryScanner.normalizeDir(path) ?? path;
    if (LibraryScanner.defaultRoots.contains(path) ||
        _scanner.customDirs.contains(path)) {
      _toast('该目录已在曲库中');
      return;
    }
    final added = await _scanner.addCustomDir(prefs, path);
    if (!added) {
      _toast('添加失败: $path');
      return;
    }
    _toast('已加入音乐库: $path');
    await _rescanFiles();
  }

  Future<void> _removeLibraryDir(String dir) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final removed = await _scanner.removeCustomDir(prefs, dir);
    if (!removed) {
      _toast('移除失败: $dir');
      return;
    }
    _toast('已移除音乐库目录: $dir');
    await _rescanFiles();
  }

  /// 本机点击文件直接播放（时长跟随定时设定，按点击时刻实时换算）；
  /// 播放状态经 StateHub 广播，远程控制页同步可见
  void _playFile(AudioFileEntry entry) {
    final playback = _playback;
    if (playback == null) {
      _toast('播放引擎尚未就绪，请稍后再试');
      return;
    }
    unawaited(playback.start(entry.path, entry.name, _computeTargetSeconds()));
    _toast('开始播放: ${entry.name}');
  }

  /// 按当前定时设定换算目标时长（秒）；off 或无效值返回 null（不限）
  int? _computeTargetSeconds() {
    if (_timerMode == 'duration') {
      final m = _timerDurationMin;
      return m > 0 ? m * 60 : null;
    }
    if (_timerMode == 'endtime' && _timerEndTime != null) {
      final now = DateTime.now();
      var end = DateTime(
          now.year, now.month, now.day, _timerEndTime!.hour, _timerEndTime!.minute);
      if (!end.isAfter(now)) end = end.add(const Duration(days: 1));
      return end.difference(now).inSeconds;
    }
    return null;
  }

  /// 定时设定变更：重算并生效；正在播放时立即生效，同时广播网页端
  void _applyTimerSetting() {
    _targetSeconds = _computeTargetSeconds();
    _playerState.targetDuration = _targetSeconds;
    _hub?.broadcast();
    if (mounted) setState(() {});
    unawaited(_persistTimerSettings());
  }

  Future<void> _persistTimerSettings() async {
    final p = _prefs;
    if (p == null) return;
    try {
      await p.setString('timer_mode', _timerMode);
      await p.setInt('timer_duration_min', _timerDurationMin);
      final t = _timerEndTime;
      await p.setString(
          'timer_endtime', t == null ? '07:00' : '${t.hour}:${t.minute}');
    } catch (e) {
      debugPrint('[设置] 定时设定持久化失败: $e');
    }
  }

  /// 从持久化恢复定时设定（bootstrap 调用）
  Future<void> _restoreTimerSettings() async {
    final p = _prefs;
    if (p == null) return;
    try {
      _timerMode = p.getString('timer_mode') ?? 'off';
      _timerDurationMin = p.getInt('timer_duration_min') ?? 30;
      final hm = p.getString('timer_endtime');
      if (hm != null && hm.contains(':')) {
        final parts = hm.split(':');
        final h = int.tryParse(parts[0]) ?? 7;
        final m = int.tryParse(parts[1]) ?? 0;
        _timerEndTime = TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
      } else {
        _timerEndTime = const TimeOfDay(hour: 7, minute: 0);
      }
    } catch (e) {
      debugPrint('[设置] 定时设定恢复失败: $e');
    }
  }

  /// 播放结束回调：先向网页端广播事件，再按开关决定是否弹窗提示关闭蓝牙
  void _handlePlaybackEnded(String reason) {
    _hub?.broadcastEvent('playback_ended', <String, dynamic>{'reason': reason});
    if (reason != 'timer') return;
    if (!_playerState.bluetoothPromptAfterPlay) return;
    if (!mounted) return;
    unawaited(_showBluetoothEndPrompt());
  }

  Future<void> _showBluetoothEndPrompt() async {
    bool? openSettings;
    try {
      openSettings = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('播放已结束'),
          content: const Text('播放已结束，要关闭蓝牙吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('保持开启'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('跳到蓝牙设置页'),
            ),
          ],
        ),
      );
    } catch (e, st) {
      debugPrint('[蓝牙] 结束提示弹窗异常: $e\n$st');
      return;
    }
    if (openSettings == true) await _openBluetoothPanel();
  }

  /// 打开系统蓝牙设置页；应用无法直接关闭蓝牙，由用户在系统界面完成
  Future<void> _openBluetoothPanel() async {
    final opened = await _bluetoothBridge.openPanel();
    if (!opened) {
      _toast('无法打开蓝牙设置页，请在系统设置中关闭蓝牙');
    }
  }

  /// 切换「播放结束提示关闭蓝牙」：更新状态、持久化、广播，
  /// 开启时顺带申请蓝牙权限（Android 12+ 的 BLUETOOTH_CONNECT）
  Future<void> _toggleBluetoothPrompt(bool value) async {
    _playerState.bluetoothPromptAfterPlay = value;
    if (mounted) setState(() {});
    _hub?.broadcast();
    final p = _prefs;
    if (p != null) {
      try {
        await p.setBool(_bluetoothPromptKey, value);
      } catch (e) {
        debugPrint('[设置] 蓝牙提示开关持久化失败: $e');
      }
    }
    if (!value) return;
    final granted = await _bluetoothBridge.ensurePermission();
    if (!granted && mounted) {
      _toast('未授予蓝牙权限，结束提示无法打开蓝牙设置页');
    }
  }

  Future<void> _copyAddress(String url) async {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('已复制: $url'),
            duration: const Duration(seconds: 1)));
    } catch (e) {
      debugPrint('[UI] 复制失败: $e');
    }
  }

  String _formatTime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Row(
          children: [
            Text('🎵 音频播放器',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    foreground: Paint()
                      ..shader = LinearGradient(colors: [
                        scheme.primary,
                        scheme.secondary,
                      ]).createShader(const Rect.fromLTWH(0, 0, 200, 40)))),
          ],
        ),
      ),
      body: _buildBody(scheme),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_booting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_bootError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              const Text('服务启动失败',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SelectableText(_bootError!,
                  style: TextStyle(color: Colors.white.withAlpha(153))),
              const SizedBox(height: 16),
              FilledButton(onPressed: _bootstrap, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final leftColumn = <Widget>[
      _buildServerCard(scheme),
      if (!_permissionGranted) ...[
        const SizedBox(height: 10),
        _buildPermissionBanner(scheme),
      ],
      const SizedBox(height: 10),
      _buildNowPlayingCard(scheme),
    ];
    const gap = SizedBox(height: 10);

    // 平板/横屏（宽 ≥720）：左栏服务与播放控制、右栏音乐库；窄屏保持单列
    return RefreshIndicator(
      onRefresh: _rescanFiles,
      child: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        if (!wide) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              ...leftColumn,
              gap,
              _buildLibraryCard(scheme),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(children: leftColumn),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 6,
                  child: _buildLibraryCard(scheme),
                ),
              ],
            ),
          ],
        );
      }),
    );
  }

  Widget _card(ColorScheme scheme, {required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(20),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _buildServerCard(ColorScheme scheme) {
    final running = _server?.isRunning ?? false;
    return _card(scheme, children: [
      Row(children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: running ? const Color(0xFF00D480) : Colors.redAccent,
          ),
        ),
        const SizedBox(width: 8),
        Text(running ? '控制服务运行中' : '服务未运行',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const Spacer(),
        IconButton(
          onPressed: _refreshAddresses,
          icon: const Icon(Icons.refresh, size: 20),
          tooltip: '刷新本机地址',
        ),
      ]),
      const SizedBox(height: 4),
      if (_addresses.isEmpty)
        Text('未获取到局域网地址，请检查 Wi-Fi 连接',
            style: TextStyle(color: Colors.white.withAlpha(140), fontSize: 13))
      else
        ..._addresses.map((url) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(url,
                        style: TextStyle(
                            color: scheme.primary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _copyAddress(url),
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '复制地址',
                  ),
                ],
              ),
            )),
      const SizedBox(height: 6),
      Text('其他手机浏览器打开以上地址即可遥控；音频放入 Music 或 Download，'
          '或在下方文件库点 ＋ 把任意文件夹加入音乐库。',
          style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 12)),
    ]);
  }

  Widget _buildPermissionBanner(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFF9800).withAlpha(36),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFF9800).withAlpha(80)),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_off_outlined, size: 20, color: Color(0xFFFFB74D)),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('未授予音频文件访问权限，公共目录不可见',
                style: TextStyle(fontSize: 13)),
          ),
          TextButton(onPressed: _retryPermission, child: const Text('授权')),
        ],
      ),
    );
  }

  Widget _buildNowPlayingCard(ColorScheme scheme) {
    final st = _playerState;
    final playing = st.isPlaying;
    final statusText = !playing
        ? '空闲'
        : st.isFadingOut
            ? '淡出中...'
            : '正在播放';
    final remaining = playing && st.targetDuration != null
        ? max(0, st.targetDuration! - st.elapsedSeconds)
        : null;

    return _card(scheme, children: [
      Row(
        children: [
          Expanded(
            child: Text(st.currentFile ?? '未在播放',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: _openBluetoothPanel,
            icon: const Icon(Icons.bluetooth, size: 20),
            tooltip: '打开蓝牙设置页',
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(statusText,
          style: TextStyle(
              fontSize: 13,
              color: playing ? scheme.primary : Colors.white.withAlpha(130))),
      const SizedBox(height: 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _stat('${_formatTime(st.elapsedSeconds)}', '已播'),
          _stat('${st.loopCount}', '循环'),
          _stat(remaining == null ? '--:--' : _formatTime(remaining), '剩余'),
        ],
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF5252),
            side: BorderSide(color: const Color(0xFFFF5252).withAlpha(90)),
          ),
          onPressed: playing ? () => _playback?.triggerStop() : null,
          icon: const Icon(Icons.stop_circle_outlined, size: 20),
          label: Text(st.isFadingOut ? '淡出中...' : '淡出停止（${kFadeDurationSeconds}s）'),
        ),
      ),
      const SizedBox(height: 6),
      _volumeSlider(
        icon: Icons.volume_up_outlined,
        label: '播放音量',
        value: st.volume.toDouble(),
        onChanged: (v) {
          st.volume = v.round();
          if (mounted) setState(() {});
          _hub?.broadcast();
        },
        onChangeEnd: (v) {
          final p = _prefs;
          if (p != null) unawaited(p.setInt(_volumeKey, v.round()));
          _hub?.broadcast();
        },
      ),
      _volumeSlider(
        icon: Icons.speaker_outlined,
        label: '系统媒体音量',
        value: st.systemVolume.clamp(0, 100).toDouble(),
        onChanged: (v) {
          final nv = v.round();
          if (nv == st.systemVolume) return;
          st.systemVolume = nv;
          if (mounted) setState(() {});
          unawaited(
              _bridge?.setVolume(nv).catchError((_) => false) ?? Future.value(false));
          _hub?.broadcast();
        },
        onChangeEnd: (v) {
          // 松手时按最终值再提交一次，确保系统音量精确落位
          unawaited(_bridge
                  ?.setVolume(v.round())
                  .catchError((_) => false) ??
              Future.value(false));
          _hub?.broadcast();
        },
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          Icon(Icons.timer_outlined, size: 16, color: Colors.white.withAlpha(140)),
          const SizedBox(width: 6),
          Text('本次播放时长',
              style: TextStyle(fontSize: 12, color: Colors.white.withAlpha(150))),
        ],
      ),
      const SizedBox(height: 6),
      SizedBox(
        width: double.infinity,
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'off', label: Text('不限')),
            ButtonSegment(value: 'duration', label: Text('按时长')),
            ButtonSegment(value: 'endtime', label: Text('按到点')),
          ],
          selected: {_timerMode},
          showSelectedIcon: false,
          onSelectionChanged: (selection) {
            _timerMode = selection.first;
            _applyTimerSetting();
          },
        ),
      ),
      if (_timerMode == 'duration') ...[
        const SizedBox(height: 6),
        Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _timerDurationMin =
                    (_timerDurationMin - 5).clamp(0, 23 * 60 + 59);
                _applyTimerSetting();
              },
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              tooltip: '减少 5 分钟',
            ),
            Expanded(
              child: Text(_formatDurationMinutes(_timerDurationMin),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _timerDurationMin =
                    (_timerDurationMin + 5).clamp(0, 23 * 60 + 59);
                _applyTimerSetting();
              },
              icon: const Icon(Icons.add_circle_outline, size: 20),
              tooltip: '增加 5 分钟',
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          children: [
            for (final m in const [15, 30, 60, 120])
              ActionChip(
                label: Text(m >= 60 ? '${m ~/ 60}时' : '$m分',
                    style: const TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  _timerDurationMin = m;
                  _applyTimerSetting();
                },
              ),
          ],
        ),
      ],
      if (_timerMode == 'endtime') ...[
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(Icons.schedule, size: 16, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
                _timerEndTime == null
                    ? '未设置结束时刻'
                    : '播放到 ${_timerEndTime!.format(context)}',
                style: const TextStyle(fontSize: 13)),
            const Spacer(),
            FilledButton.tonal(
              onPressed: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: _timerEndTime ?? const TimeOfDay(hour: 7, minute: 0),
                );
                if (picked == null || !mounted) return;
                _timerEndTime = picked;
                _applyTimerSetting();
              },
              child: const Text('选择时刻'),
            ),
          ],
        ),
      ],
      const SizedBox(height: 2),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: st.bluetoothPromptAfterPlay,
        onChanged: _toggleBluetoothPrompt,
        title: const Text('播放结束提示关闭蓝牙',
            style: TextStyle(fontSize: 13)),
        subtitle: Text('播放结束将跳转到蓝牙设置页，需手动关闭',
            style: TextStyle(
                fontSize: 11, color: Colors.white.withAlpha(120))),
      ),
    ]);
  }

  String _formatDurationMinutes(int totalMinutes) {
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (h > 0 && m > 0) return '$h 小时 $m 分钟';
    if (h > 0) return '$h 小时';
    return '$m 分钟';
  }

  Widget _volumeSlider({
    required IconData icon,
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    void step(int delta) {
      final nv = (value.round() + delta).clamp(0, 100).toDouble();
      if (nv == value) return;
      onChanged(nv);
      onChangeEnd(nv);
    }

    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.white.withAlpha(140)),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () => step(-1),
          icon: const Icon(Icons.remove, size: 18),
          tooltip: '$label -1',
        ),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 100,
            divisions: 100,
            label: '${value.round()}',
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () => step(1),
          icon: const Icon(Icons.add, size: 18),
          tooltip: '$label +1',
        ),
        SizedBox(
          width: 30,
          child: Text('${value.round()}',
              textAlign: TextAlign.end,
              style: TextStyle(
                  fontSize: 12, color: Colors.white.withAlpha(150))),
        ),
      ],
    );
  }

  Widget _stat(String value, String label) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF00D4FF))),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 11, color: Colors.white.withAlpha(128))),
      ],
    );
  }

  Widget _buildLibraryCard(ColorScheme scheme) {
    final entries = _scanner.entries;
    return _card(scheme, children: [
      Row(
        children: [
          Text('文件库：${entries.length} 个',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          if (_scanning)
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
          else ...[
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: _showAddLibraryDialog,
              icon: const Icon(Icons.create_new_folder_outlined, size: 20),
              tooltip: '添加音乐库目录',
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: _rescanFiles,
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: '重新扫描',
            ),
          ],
        ],
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final root in LibraryScanner.defaultRoots)
            Tooltip(
              message: root,
              child: Chip(
                label: Text(_dirLabel(root),
                    style: const TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
              ),
            ),
          for (final dir in _scanner.customDirs)
            Tooltip(
              message: dir,
              child: InputChip(
                label: Text(_dirLabel(dir),
                    style: TextStyle(fontSize: 11, color: scheme.primary)),
                visualDensity: VisualDensity.compact,
                onDeleted: () => _removeLibraryDir(dir),
              ),
            ),
        ],
      ),
      if (_scanner.lastError != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('部分目录无法读取: ${_scanner.lastError}',
              style: const TextStyle(fontSize: 12, color: Color(0xFFFFB74D))),
        ),
      const SizedBox(height: 6),
      if (entries.isEmpty)
        Text('没有找到音频文件。点上方 ＋ 把任意文件夹加入音乐库，'
            '或把文件放入 Music、Download 后刷新。',
            style: TextStyle(color: Colors.white.withAlpha(130), fontSize: 12))
      else
        ...entries.take(50).map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _playFile(e),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 4, horizontal: 4),
                  child: Row(
                    children: [
                      Icon(Icons.music_note,
                          size: 16, color: scheme.primary.withAlpha(200)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13))),
                      const SizedBox(width: 8),
                      Text(LibraryScanner.formatFileSize(e.rawSize),
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withAlpha(110))),
                      const SizedBox(width: 6),
                      Icon(Icons.play_circle_outline,
                          size: 20, color: scheme.primary.withAlpha(180)),
                    ],
                  ),
                ),
              ),
            )),
      if (entries.length > 50)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('… 其余 ${entries.length - 50} 个见网页端列表',
              style: TextStyle(
                  fontSize: 12, color: Colors.white.withAlpha(110))),
        ),
    ]);
  }
}
