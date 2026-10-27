#!/bin/bash
# Compile the bundled source locally; detailed output goes to install.log.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Applications/ScreenLingo.app"
LOG="$ROOT/install.log"
WORK=""
BACKUP=""
STAGE="准备安装"

pause() { printf '\n按回车键关闭。'; read -r _ || true; }
cleanup() { if [ -n "$WORK" ] && [ -d "$WORK" ]; then /bin/rm -rf "$WORK"; fi; }
failed() {
  local status=$?
  trap - ERR
  # A backup only exists if an installed app was actually moved aside.
  if [ -n "$BACKUP" ] && [ -e "$BACKUP" ] && [ ! -e "$DEST" ]; then
    if /bin/mv "$BACKUP" "$DEST" >>"$LOG" 2>&1; then
      printf '\n已恢复原安装。\n'
    else
      printf '\n原安装保留在：%s\n' "$BACKUP"
    fi
  fi
  printf '\n安装失败（%s），详情见：%s\n' "$STAGE" "$LOG"
  pause
  exit "$status"
}
trap cleanup EXIT
trap failed ERR

if [ "$(/usr/bin/uname -s)" != Darwin ]; then
  printf '请在 Mac 上运行。\n'; exit 1
fi
MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
if [ "$MAJOR" -lt 13 ]; then
  printf '需要 macOS 13 或更新版本。\n'; pause; exit 1
fi
if ! /usr/bin/xcrun --sdk macosx --find swiftc >/dev/null 2>&1 || ! /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  printf '请完成弹出的 Apple Command Line Tools 安装，然后重新运行本文件。\n'
  /usr/bin/xcode-select --install >/dev/null 2>&1 || true
  pause; exit 0
fi
if /usr/bin/pgrep -x ScreenLingo >/dev/null 2>&1; then
  printf '请先退出正在运行的 ScreenLingo。\n'; pause; exit 1
fi
ARCH="$(/usr/bin/uname -m)"
if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || printf 0)" = 1 ]; then ARCH=arm64; fi
case "$ARCH" in arm64|x86_64) ;; *) printf '不支持的架构：%s\n' "$ARCH"; pause; exit 1;; esac
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
printf 'ScreenLingo 0.3.1\nArchitecture: %s\nSDK: %s\n' "$ARCH" "$SDK" >"$LOG"
/usr/bin/sw_vers >>"$LOG" 2>&1
/usr/bin/xcrun --sdk macosx swiftc --version >>"$LOG" 2>&1
printf '正在安装 ScreenLingo…\n'

# Stage on the destination volume so replacement is a rename, not a partial copy.
/bin/mkdir -p "$HOME/Applications" >>"$LOG" 2>&1
WORK="$(/usr/bin/mktemp -d "$HOME/Applications/.ScreenLingo-build.XXXXXX")"
APP="$WORK/ScreenLingo.app"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" >>"$LOG" 2>&1

STAGE="应用编译"
printf '\n[Application build]\n' >>"$LOG"
/usr/bin/xcrun --sdk macosx swiftc -O -swift-version 5 -parse-as-library \
  -target "$ARCH-apple-macosx13.0" -sdk "$SDK" -module-cache-path "$WORK/ModuleCache" \
  "$ROOT/Sources/Core.swift" "$ROOT/Sources/FloatingUI.swift" \
  "$ROOT/Sources/TranslationOverlay.swift" "$ROOT/Sources/Uninstall.swift" "$ROOT/Sources/App.swift" \
  -framework Cocoa -framework WebKit -framework Security -framework Carbon -framework CoreGraphics \
  -framework LocalAuthentication -framework UniformTypeIdentifiers \
  -o "$APP/Contents/MacOS/ScreenLingo" >>"$LOG" 2>&1
STAGE="应用打包"
printf '\n[Bundle and signature]\n' >>"$LOG"
/bin/cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist" >>"$LOG" 2>&1
for f in index.html style.css app.js overlay.html overlay.css overlay.js AppIcon.icns; do
  /bin/cp "$ROOT/Resources/$f" "$APP/Contents/Resources/$f" >>"$LOG" 2>&1
done
/bin/chmod 755 "$APP/Contents/MacOS/ScreenLingo" >>"$LOG" 2>&1
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >>"$LOG" 2>&1
/usr/bin/codesign --force --sign - --identifier local.screenlingo.app --timestamp=none "$APP" >>"$LOG" 2>&1
/usr/bin/codesign --verify --deep --strict "$APP" >>"$LOG" 2>&1

STAGE="完成安装"
if [ -e "$DEST" ]; then
  BACKUP="$DEST.previous-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mv "$DEST" "$BACKUP" >>"$LOG" 2>&1
  printf 'Previous installation: %s\n' "$BACKUP" >>"$LOG"
fi
/bin/mv "$APP" "$DEST" >>"$LOG" 2>&1
if /usr/bin/open "$DEST" >>"$LOG" 2>&1; then
  printf '安装完成，已打开 ScreenLingo。\n'
else
  printf '安装完成，请手动打开：%s\n' "$DEST"
fi
pause
