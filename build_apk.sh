#!/bin/bash
# 局域网音频播放器·安卓服务端 APK 构建脚本
# 与 rent_meter 项目相同的构建流程：
#   源码在 hgfs 共享目录（Windows 可访问），rsync 到 Linux 原生目录构建
#   （避免 hgfs 慢 I/O 和不支持符号链接），APK 拷回共享目录。
set -e
# 管道中任一命令失败都触发 set -e(否则 flutter build | tee 失败会被 tee 的退出码掩盖)
set -o pipefail

# 源码目录自动探测（按优先级）；都不存在时可用 SRC_DIR=/路径 显式指定
if [ -z "$SRC_DIR" ]; then
  for candidate in \
    /mnt/hgfs/Share/Projects/audio-player-android \
    /mnt/hgfs/Share/audio-player-android \
    /mnt/hgfs/MyProjects/audio-player/audio-player-android; do
    if [ -f "$candidate/pubspec.yaml" ]; then
      SRC_DIR="$candidate"
      break
    fi
  done
fi
if [ -z "$SRC_DIR" ] || [ ! -f "$SRC_DIR/pubspec.yaml" ]; then
  echo "==> 未找到源码目录。请把 audio-player-android 放入虚拟机可见的共享目录，"
  echo "    或显式指定：SRC_DIR=/mnt/hgfs/Share/xxx $0"
  exit 1
fi

BUILD_DIR=${BUILD_DIR:-/home/twave/audio_player_build}
FLUTTER=/opt/flutter/bin/flutter
DART=/opt/flutter/bin/dart
export ANDROID_HOME=/opt/android-sdk
export PATH="/opt/flutter/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
export GRADLE_USER_HOME="$HOME/.gradle"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
unset FLUTTER_STORAGE_BASE_URL
# 清掉 shell 里残留的代理变量：国内镜像直连即可，走代理反而把国内流量绕到国外变慢
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy

# 构建日志：hgfs 共享目录不支持「truncate 后以 O_APPEND 追加」——截断后 guest 端
# 缓存的旧文件大小不失效，tee -a 会从陈旧的 EOF 偏移开始写，产生前段全 NUL 的错位文件。
# 因此日志始终写构建目录下的本地文件，脚本退出时（无论成败）一次性整文件拷回项目根目录。
LOG_FILE="$SRC_DIR/build_log.txt"
LOG_LOCAL="$BUILD_DIR/build_log.txt"
: > "$LOG_LOCAL"
sync_log() {
  local stamp archive_dir
  stamp="$(date +%Y%m%d_%H%M)"
  archive_dir="$SRC_DIR/logs"
  mkdir -p "$archive_dir" 2>/dev/null || true
  # 时间戳归档：hgfs 对同名文件的反复覆写不可靠（内容会错位拼接），唯一文件名写入可靠；
  # 归档只保留最近 10 份
  if cp -f "$LOG_LOCAL" "$archive_dir/build_log_${stamp}.txt" 2>/dev/null; then
    ls -1t "$archive_dir"/build_log_*.txt 2>/dev/null | tail -n +11 | xargs -r rm -f
  fi
  # 规范名日志：先删旧文件再重建（全新目录项可避开 hgfs 的陈旧缓存状态）
  rm -f "$LOG_FILE"
  if ! cp -f "$LOG_LOCAL" "$LOG_FILE" 2>/dev/null; then
    echo "==> 警告: 构建日志未能拷回共享目录: $LOG_FILE" >&2
  fi
}
trap sync_log EXIT
echo "==> 构建日志: $LOG_FILE (每次构建覆盖)"

command -v rsync >/dev/null || { echo "需要 rsync：sudo apt install -y rsync"; exit 1; }

echo "==> 源码: $SRC_DIR"
echo "==> 构建: $BUILD_DIR"
$FLUTTER --version | tee -a "$LOG_LOCAL"

# 清除 pub advisories 缓存（pub 已知 bug：镜像 advisories 数据会让 readAdvisoriesFromCache 崩溃）
find ~/.pub-cache -iname "*advisories*" -exec rm -rf {} + 2>/dev/null || true

# 同步源码到原生目录（排除构建产物 / git / 旧 apk / 插件注册点文件 / 构建日志与归档；
# 原生目录里的 build/ 和 .dart_tool/ 保留做原生层增量）。
# 不带 -a 的 -t 位：hgfs 报告的源文件修改时间可能过期，落地旧时间戳会让 Flutter
# 增量编译误判「文件没变」而沿用旧产物；目标文件一律使用当前时间。
echo "==> rsync 同步源码到原生目录..."
rsync -rlpgoD --delete --checksum \
  --exclude build --exclude .dart_tool --exclude .git --exclude '*.apk' \
  --exclude .flutter-plugins --exclude .flutter-plugins-dependencies \
  --exclude 'build_log*.txt' --exclude '/logs/' \
  "$SRC_DIR/" "$BUILD_DIR/"

# 源码自检：把共享目录侧与构建目录侧的关键文件指纹写入日志，
# 用于定位「编译产物与源码不符」时到底是哪一侧的内容出了问题
echo "==> 源码自检:" | tee -a "$LOG_LOCAL"
for f in lib/media/library_scanner.dart lib/ui/home_screen.dart; do
  src_md5=$(md5sum "$SRC_DIR/$f" 2>/dev/null | cut -d' ' -f1)
  bld_md5=$(md5sum "$BUILD_DIR/$f" 2>/dev/null | cut -d' ' -f1)
  src_hit=$(grep -c 'defaultRoots' "$SRC_DIR/$f" 2>/dev/null) || true
  bld_hit=$(grep -c 'defaultRoots' "$BUILD_DIR/$f" 2>/dev/null) || true
  echo "    $f" | tee -a "$LOG_LOCAL"
  echo "      共享目录侧: md5=${src_md5:-读取失败} defaultRoots=${src_hit:-读取失败}" | tee -a "$LOG_LOCAL"
  echo "      构建目录侧: md5=${bld_md5:-读取失败} defaultRoots=${bld_hit:-读取失败}" | tee -a "$LOG_LOCAL"
done

echo "    构建目录内所有 library_scanner.dart:" | tee -a "$LOG_LOCAL"
find "$BUILD_DIR" -name 'library_scanner.dart' -not -path "$BUILD_DIR/build/*" \
  -exec md5sum {} \; 2>/dev/null | tee -a "$LOG_LOCAL"

# 停止旧 Gradle daemon
echo "==> 停止旧 Gradle daemon..."
( cd "$BUILD_DIR/android" && ./gradlew --stop 2>/dev/null ) || true
pkill -f gradle 2>/dev/null || true
sleep 2

cd "$BUILD_DIR"
if [ "${CLEAN:-0}" = "1" ]; then
  echo "==> flutter clean"
  $FLUTTER clean
fi

# 清理 Dart 增量编译缓存与包解析元数据：源文件经共享目录同步后时间戳可能滞后，
# 残留的 kernel 缓存或过期的 package_config 会让编译沿用与源码不符的旧符号；
# .dart_tool 由随后的 pub get 全量重建，代价可忽略
rm -rf "$BUILD_DIR/.dart_tool"

# 1) 项目依赖：用 flutter pub get（而非 dart pub get）——只有 flutter pub get 会在构建目录
#    生成 .flutter-plugins-dependencies，settings.gradle 的 flutter-plugin-loader 靠它注册各
#    插件的 Android 工程；该文件缺失时插件类不在编译类路径（如 AudioServiceActivity）。
#    优先 --offline 用本地缓存；失败则回退在线拉取（新增依赖后 offline 必失败）
echo "==> flutter pub get --offline（项目依赖）" | tee -a "$LOG_LOCAL"
if ! $FLUTTER pub get --offline 2>&1 | tee -a "$LOG_LOCAL"; then
  echo "==> 离线失败，回退在线 pub get（首次拉取新依赖）..." | tee -a "$LOG_LOCAL"
  if ! $FLUTTER pub get 2>&1 | tee -a "$LOG_LOCAL"; then
    echo "==> pub get 失败。看日志: tail -50 ~/.pub-cache/log/pub_log.txt" | tee -a "$LOG_LOCAL"
    exit 1
  fi
fi

# 把更新后的 pubspec.lock 拷回源码目录：
# 否则 rsync --delete 会用源码里的旧 lock 覆盖 BUILD_DIR 的新 lock，
# 导致新增依赖后每次构建都重复在线拉取。
cp -f "$BUILD_DIR/pubspec.lock" "$SRC_DIR/pubspec.lock" 2>/dev/null || true
echo "==> pubspec.lock 已同步回源码目录" | tee -a "$LOG_LOCAL"

# 包解析自检（pub get 之后、编译之前）：编译器经 package:audio_player URI 解析出的
# 物理路径必须落在构建目录内；同时列出构建目录下全部同名文件，暴露历史遗留副本
echo "==> 包解析自检:" | tee -a "$LOG_LOCAL"
echo "    构建目录内所有 library_scanner.dart:" | tee -a "$LOG_LOCAL"
find "$BUILD_DIR" -name 'library_scanner.dart' -not -path "$BUILD_DIR/build/*" \
  -exec md5sum {} \; 2>/dev/null | tee -a "$LOG_LOCAL"
echo "    package_config 中 audio_player 条目上下文:" | tee -a "$LOG_LOCAL"
grep -n -A4 '"audio_player"' "$BUILD_DIR/.dart_tool/package_config.json" 2>/dev/null \
  | tee -a "$LOG_LOCAL" || echo "    (未找到 audio_player 条目)" | tee -a "$LOG_LOCAL"

# Dart 编译器视角复现：不经 gradle，直接静态分析这两个文件。
# 若此处同样报 defaultRoots 未定义，则问题在包解析/文件层；若此处通过，
# 则问题在 flutter build 的输入组装环节。
echo "==> dart analyze 复现:" | tee -a "$LOG_LOCAL"
$DART analyze lib 2>&1 | tail -n 40 | tee -a "$LOG_LOCAL" || true
echo "==> dart pub get --example --offline（flutter_tools）" | tee -a "$LOG_LOCAL"
if ! ( cd /opt/flutter/packages/flutter_tools && $DART pub get --example --offline 2>&1 | tee -a "$LOG_LOCAL" ); then
  echo "==> flutter_tools pub get 失败。看日志: tail -50 ~/.pub-cache/log/pub_log.txt" | tee -a "$LOG_LOCAL"
  exit 1
fi

# 版本号：版本名 + 自增 build 号 + 时间戳
VERSION=$(grep '^version:' "$SRC_DIR/pubspec.yaml" | awk '{print $2}' | cut -d '+' -f 1)
BN_FILE="$SRC_DIR/.build_number"
BN=$(cat "$BN_FILE" 2>/dev/null || echo 0)
BN=$((BN + 1))
echo "$BN" > "$BN_FILE"
TIMESTAMP=$(date +%Y%m%d_%H%M)
VER_STR="${VERSION}+${BN}_${TIMESTAMP}"
echo "==> 版本: $VER_STR" | tee -a "$LOG_LOCAL"

# 构建（--no-pub 跳过 Flutter 自带在线 pub get；arm64 only 省编译时间；
# --build-name 带 build 号+时间戳，--build-number 递增便于覆盖升级）
echo "==> flutter build apk --release" | tee -a "$LOG_LOCAL"
$FLUTTER build apk --no-pub --release --no-shrink --target-platform android-arm64 \
  --build-name="$VER_STR" --build-number="$BN" 2>&1 | tee -a "$LOG_LOCAL"

# APK 拷回项目根目录（文件名带版本+build 号+时间戳）
APK="$BUILD_DIR/build/app/outputs/flutter-apk/app-release.apk"
DEST="$SRC_DIR/音频播放器_v${VER_STR}.apk"
cp "$APK" "$DEST"
echo ""
echo "==> 完成: $DEST" | tee -a "$LOG_LOCAL"
echo "    （构建于 $BUILD_DIR，已拷回项目根目录）" | tee -a "$LOG_LOCAL"
