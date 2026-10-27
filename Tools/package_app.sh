#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
swift build -c release

APP_NAME="提醒条"
APP="$ROOT/dist/$APP_NAME.app"
mkdir -p "$ROOT/dist"
if [[ -e "$APP" ]]; then
  mkdir -p "$ROOT/dist/previous"
  rm -rf "$ROOT/dist/previous/$APP_NAME.app"
  mv "$APP" "$ROOT/dist/previous/$APP_NAME.app"
  echo "Previous bundle moved to: dist/previous/$APP_NAME.app"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RemindBar "$APP/Contents/MacOS/RemindBar"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleDisplayName</key><string>提醒条</string>
<key>CFBundleName</key><string>提醒条</string>
<key>CFBundleExecutable</key><string>RemindBar</string>
<key>CFBundleIdentifier</key><string>com.laziji.remindbar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>提醒条用麦克风听你口述提醒内容，并转成文字。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>提醒条用语音识别把你口述的提醒转成文字（优先在本机识别）。</string>
<key>NSRemindersFullAccessUsageDescription</key><string>提醒条用它和“提醒事项”双向同步：把提醒条里的提醒写进「提醒条」列表，并把你在提醒事项里新增、修改、勾选的内容同步回来。</string>
<key>NSRemindersUsageDescription</key><string>提醒条用它和“提醒事项”双向同步：把提醒条里的提醒写进「提醒条」列表，并把你在提醒事项里新增、修改、勾选的内容同步回来。</string>
</dict></plist>
PLIST

# Do not enable the hardened runtime here: microphone access would then need an extra audio-input entitlement.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null
  echo "Applied ad-hoc development signature."
else
  echo "codesign is unavailable; bundle remains unsigned."
fi
echo "Created: $APP"
echo "This is a local development bundle; use Developer ID signing and notarization before distribution."
