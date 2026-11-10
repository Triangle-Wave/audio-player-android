# 局域网音频播放器 · 安卓服务端

PC 版（Node.js）的安卓移植：把"播放主机 + 控制服务器"整体装进一台安卓设备，
局域网内其他手机/电脑用浏览器打开 `http://安卓IP:31901/control` 即可遥控。

## 架构

| PC 版实现 | 安卓版实现 |
|---|---|
| Node.js express + ws | Flutter 内嵌 `shelf` HTTP/WebSocket 服务器（端口同为 31901） |
| PowerShell 驱动 WPF MediaPlayer 播放 | `just_audio`（ExoPlayer 内核）+ `just_audio_background` 前台服务 |
| uploads 文件夹 | 音乐库目录：内置 `/sdcard/Music`、`/sdcard/Download` 与应用专属目录，可在 App 内添加/移除自定义目录（持久化） |
| `.volume` 文件记忆音量 | SharedPreferences 记忆 |
| Windows COM 控系统音量 | MethodChannel 调 Android AudioManager（媒体音量） |

- 网页控制端**原样复用** PC 版的 `public/control.html`（打包进 APK 资产，由内嵌服务器提供）
- API 与 PC 版逐条兼容，见下文清单

## 功能

- 播放音频（mp4/mp3/aac/wav/flac/m4a 等；视频文件仅取音轨）
- 定时循环播放：按时长 / 按结束时间（前端换算成时长下发），最后 10 秒淡出
- 手动停止同样 10 秒淡出（15 秒强制兜底）
- 手机浏览器遥控 + WebSocket 实时状态推送
- 锁屏/后台持续播放：前台媒体服务 + WakeLock
- 播放音量记忆、系统媒体音量调节

## 构建（在虚拟机上执行）

源码目录需虚拟机可见（hgfs 共享）。任选其一：

1. 把 `audio-player-android` 整个文件夹拷到现有共享目录，如 `G:\Share\Projects\audio-player-android`
2. 或在 VMware 里把 `G:\MyProjects` 也设为共享文件夹

然后在虚拟机中：

```bash
cd <共享目录挂载点>/audio-player-android   # 如 /mnt/hgfs/Share/Projects/audio-player-android
./build_apk.sh
```

脚本会 rsync 到 `/home/twave/audio_player_build` 原生目录做增量构建
（同步不保留源文件时间戳，且每次清理 Dart 增量编译缓存，避免共享目录时间戳
异常导致增量编译沿用旧产物），产物 `音频播放器_v<版本>+<build>_<时间戳>.apk`
拷回项目根目录。
可选环境变量：`CLEAN=1` 全新构建、`SRC_DIR=...` 显式指定源码路径、`BUILD_DIR=...` 指定构建目录。

依赖与工具链沿用 rent_meter 的环境约定：Flutter 在 `/opt/flutter`、Android SDK 在 `/opt/android-sdk`、
Gradle 8.3 wrapper、阿里云 Maven 镜像、pub 镜像 `flutter-io.cn`。

## 使用

1. 安装 APK，启动后授予"音乐和音频"访问权限（Android 13+ 为 READ_MEDIA_AUDIO + 通知权限）
2. 把音频文件放入设备的 `Music` 或 `Download` 目录（或 `adb push` 到
   `/sdcard/Android/data/com.twave.audio_player/files/`），App 内点刷新或下拉刷新；
   也可在「文件库」卡片点 ＋ 调起系统文件管理器选择任意文件夹加入音乐库
   （首次需按引导授予"所有文件访问"权限，目录列表跨启动记忆），自定义目录可随时点 × 移除
3. 其他设备浏览器访问 App 首页显示的地址，如 `http://192.168.x.x:31901/control`

## API 兼容性清单（与 Node 版一致）

| 路由 | 说明 |
|---|---|
| `GET /control`、`GET /control.html` | 网页控制端 |
| `POST /api/play` `{file, targetDuration, audioDevice, volume}` | 开始播放（targetDuration 秒） |
| `POST /api/stop` | 触发淡出停止 |
| `POST /api/volume` `{volume}` | 播放音量（0-100，持久化） |
| `GET /api/system-volume` / `POST /api/system-volume` | 系统（媒体）音量读取/设置 |
| `GET /api/files` | 扫描结果列表 `{name, size, rawSize, modified}` |
| `GET /api/devices` | 固定返回默认输出设备（Android 无切换接口，保证前端兼容） |
| `GET /api/state` | 当前状态快照 |
| `WS /` | 连接即推全量状态，之后每秒广播 `{type:'state_update', data:{...}}` |
| `GET /uploads/<文件名>` | 按文件名流式返回音频 |

## 已知限制

- **m4s 格式未验证**：B站缓存 m4s 是缺 init segment 的裸 fMP4 分段，ExoPlayer 可能无法直接播放；
  主力格式 mp4/mp3/flac 无此问题。如需播 m4s，建议先在 PC 上转封装为 m4a
- **系统音量即媒体音量**：控制的是 STREAM_MUSIC，非整机所有声道
- **音频输出设备固定**：走系统当前输出（扬声器/蓝牙由系统决定），`audioDevice` 参数仅作记录
- **长时间整夜播放**：请在系统设置里关闭本应用的电池优化（尤其国产 ROM 的激进省电），
  并保持媒体音量合适；前台通知常驻属正常现象

## 目录结构

```
audio-player-android/
├── build_apk.sh              # 虚拟机构建脚本
├── pubspec.yaml
├── assets/web/control.html   # 复用自 PC 版 public/control.html
├── lib/
│   ├── main.dart             # 入口：前台服务初始化
│   ├── server/
│   │   ├── http_server.dart  # shelf 路由（API 兼容层）
│   │   └── state_hub.dart    # 播放状态 + WebSocket 广播
│   ├── player/
│   │   ├── playback_service.dart   # 循环/定时/淡出引擎
│   │   └── system_volume_bridge.dart # 系统音量/权限 MethodChannel
│   ├── media/library_scanner.dart  # 音频文件扫描
│   └── ui/home_screen.dart   # 极简状态页
└── android/                  # 构建配置（权限、前台服务声明、MethodChannel）
```
